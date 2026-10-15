// FloeExecutionTests — shared-guest multi-client contract.
//
// One parent task and its full-power children share ONE Linux guest. These
// regressions drive the real production channel/registry with a scripted
// console and prove, in the standard test suite, what the qualification host
// (`Qualification/TinyEMULinux/multiclient`) proves against the real runner:
//
//   * several clients run concurrently on one guest (three EXEC frames in
//     flight at the same time, one VM session);
//   * each client keeps its own token, stdout, stderr and exit code — no
//     cross-talk and no per-client VM;
//   * cancelling one client sends a targeted interrupt for exactly that token
//     and leaves the other clients and the guest itself untouched;
//   * the bounded token stream never drops a control frame (a lost END used
//     to hang one client and could poison the shared environment channel);
//   * the bounded console fails closed (reported overflow) instead of
//     silently dropping console bytes that frame arbitrary tokens;
//   * a run's per-run environment is really applied to the guest command
//     instead of being silently discarded.

import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeExecution

// MARK: - file-local helpers (the fakes live in LinuxGuestBackendTests.swift)

private func multiDescriptor(id: String, imageID: String = "test-image") -> LinuxGuestEnvironmentDescriptor {
    LinuxGuestEnvironmentDescriptor(id: id, ownerID: "owner", imageID: imageID)
}

private func multiImage() -> LinuxGuestImage {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-multiclient-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let bios = directory.appendingPathComponent("bbl64.bin")
    let contents = Data("bios".utf8)
    FileManager.default.createFile(atPath: bios.path, contents: contents)
    let artifacts = [
        LinuxGuestImageArtifact(
            role: .bios,
            path: bios.path,
            sha512: FloeDigest.sha512Hex(contents),
            bytes: Int64(contents.count)
        )
    ]
    return LinuxGuestImage(
        id: "test-image",
        biosPath: bios.path,
        qualified: true,
        qualificationEvidence: "multi-client focused regression",
        qualificationRun: "run-multiclient",
        artifacts: artifacts
    )
}

private func multiCaps(_ token: String) -> [Data] {
    [Data("\u{1e}FLOE-CAPS \(token) runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4\u{1e}\u{1e}FLOE-END \(token) 0\u{1e}".utf8)]
}

private func multiReply(_ token: String, stdout: String, stderr: String = "", exit: Int32 = 0) -> [Data] {
    var data = Data()
    data.append(Data("\u{1e}FLOE-BEGIN \(token)\u{1e}\u{1e}FLOE-OUT \(token)\u{1e}".utf8))
    data.append(Data(stdout.utf8))
    data.append(Data("\u{1e}FLOE-ERR \(token)\u{1e}".utf8))
    data.append(Data(stderr.utf8))
    data.append(Data("\u{1e}FLOE-END \(token) \(exit)\u{1e}".utf8))
    return [data]
}

/// Holds the reply of the NEXT command token and remembers it, so the test
/// can keep exactly one client in flight while others complete.
private final class TokenHoldBox: @unchecked Sendable {
    private let lock = NSLock()
    private var holdNext = false
    private var held: String?

    func holdNextToken() {
        lock.lock()
        holdNext = true
        lock.unlock()
    }

    var heldToken: String? {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    func holds(_ token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if holdNext {
            holdNext = false
            held = token
            return true
        }
        return held == token
    }
}

final class LinuxMultiClientRegistryTests: XCTestCase {
    private func makeRegistry(
        ledger: FakeSessionLedger,
        environmentID: String,
        factory: FakeSessionFactory
    ) -> TinyEMULinuxGuestRegistry {
        TinyEMULinuxGuestRegistry(
            environments: FakeEnvironmentProvider(descriptors: [environmentID: multiDescriptor(id: environmentID)]),
            images: FakeImageResolver(images: ["test-image": multiImage()]),
            limits: .standard,
            factory: factory
        )
    }

    private func waitForExecCount(
        _ console: TestLinuxGuestConsole,
        _ expected: Int,
        deadline: TimeInterval = 5
    ) async throws -> [String] {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            let tokens = TestLinuxGuestConsole.tokens(in: console.written, name: "EXEC")
            if tokens.count >= expected { return tokens }
            try? await Task.sleep(for: .milliseconds(20))
        }
        throw FloeError.validationFailed("only \(TestLinuxGuestConsole.tokens(in: console.written, name: "EXEC").count) EXEC frame(s) reached the guest; expected \(expected)")
    }

    /// Parent + two children on ONE environment: overlapping execution,
    /// per-client identity, and a cancellation that tears down exactly the
    /// cancelled client's process group — never the shared guest.
    func testOneGuestServesConcurrentClientsWithScopedCancellation() async throws {
        let ledger = FakeSessionLedger()
        let hold = TokenHoldBox()
        let factory = FakeSessionFactory(ledger: ledger) { _, token in
            if token.hasPrefix("hello-") { return multiCaps(token) }
            if hold.holds(token) { return [Data("\u{1e}FLOE-BEGIN \(token)\u{1e}".utf8)] }
            return multiReply(token, stdout: "reply-\(token.prefix(4))")
        }
        let registry = makeRegistry(ledger: ledger, environmentID: "env-mc", factory: factory)
        _ = try await registry.start(environmentID: "env-mc", taskID: "task-parent")
        let console = try XCTUnwrap(ledger.console(for: "env-mc"))

        // 1. The long child starts first and stays in flight (its reply is held).
        hold.holdNextToken()
        let longCancellation = CancellationToken()
        async let longClient = registry.run(
            environmentID: "env-mc", argv: ["/bin/sh", "-c", "sleep 30"],
            workingDirectory: nil, standardInput: nil,
            timeout: 30, maxOutputBytes: 4096, cancellation: longCancellation
        )
        let firstWave = try await waitForExecCount(console, 1)
        let heldToken = try XCTUnwrap(hold.heldToken)
        XCTAssertEqual(firstWave, [heldToken])
        XCTAssertEqual(TestLinuxGuestConsole.tokens(in: console.written, name: "END").count, 0,
                       "the held client must still be in flight")

        // 2. Parent and the second child run WHILE the first is in flight.
        async let parentClient = registry.run(
            environmentID: "env-mc", argv: ["/bin/sh", "-c", "echo parent"],
            workingDirectory: nil, standardInput: nil,
            timeout: 10, maxOutputBytes: 4096, cancellation: nil
        )
        async let childClient = registry.run(
            environmentID: "env-mc", argv: ["/bin/sh", "-c", "echo child"],
            workingDirectory: nil, standardInput: nil,
            timeout: 10, maxOutputBytes: 4096, cancellation: nil
        )
        let allTokens = try await waitForExecCount(console, 3)
        XCTAssertEqual(Set(allTokens).count, 3, "three distinct client tokens must be in flight")
        XCTAssertTrue(allTokens.contains(heldToken))
        XCTAssertEqual(TestLinuxGuestConsole.tokens(in: console.written, name: "END").count, 0,
                       "all three clients must overlap: none finished while all three ran")

        // 3. Cancel ONLY the long client.
        longCancellation.cancel()
        let signalDeadline = Date().addingTimeInterval(5)
        var signalTokens: [String] = []
        while Date() < signalDeadline {
            signalTokens = TestLinuxGuestConsole.tokens(in: console.written, name: "SIGNAL")
            if !signalTokens.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(signalTokens, [heldToken],
                       "the interrupt must address exactly the cancelled client's token")
        // The guest reaps the cancelled process group and answers END 130;
        // only the cancelled client may observe it.
        console.push([Data("\u{1e}FLOE-BEGIN \(heldToken)\u{1e}\u{1e}FLOE-END \(heldToken) 130\u{1e}".utf8)])
        do {
            _ = try await longClient
            XCTFail("the cancelled client must report cancellation, not a result")
        } catch FloeError.cancelled {
            // expected
        }

        let parentResult = try await parentClient
        let childResult = try await childClient
        let expectedOutputs = Set(allTokens.filter { $0 != heldToken }.map { "reply-\($0.prefix(4))" })
        XCTAssertEqual(Set([parentResult.stdout, childResult.stdout]), expectedOutputs,
                       "each surviving client keeps exactly its own output")
        XCTAssertEqual(parentResult.stderr, "")
        XCTAssertEqual(childResult.stderr, "")
        XCTAssertEqual(parentResult.exitCode, 0)
        XCTAssertEqual(childResult.exitCode, 0)

        // 4. The shared guest is untouched: one session, no stop, still usable.
        XCTAssertEqual(ledger.sessionCount(for: "env-mc"), 1, "one guest serves every client")
        let running = await registry.status(environmentID: "env-mc").running
        XCTAssertTrue(running, "a scoped client cancellation must not stop the shared guest")
        let after = try await registry.run(
            environmentID: "env-mc", argv: ["/bin/sh", "-c", "echo after"],
            workingDirectory: nil, standardInput: nil,
            timeout: 10, maxOutputBytes: 4096, cancellation: nil
        )
        XCTAssertTrue(after.stdout.hasPrefix("reply-"), "the guest keeps serving new clients")
    }

    /// Two clients presenting the SAME caller-side identity (for example the
    /// same provider/model call id, which is not globally unique) still get
    /// independent transport tokens and independent output: execution
    /// correlation is minted per execution, never derived from a
    /// caller-supplied id.
    func testIdenticalCallerIdentitiesRouteIndependently() async throws {
        let ledger = FakeSessionLedger()
        let factory = FakeSessionFactory(ledger: ledger) { _, token in
            if token.hasPrefix("hello-") { return multiCaps(token) }
            return multiReply(token, stdout: "reply-\(token.prefix(4))")
        }
        let registry = makeRegistry(ledger: ledger, environmentID: "env-dup", factory: factory)
        _ = try await registry.start(environmentID: "env-dup", taskID: "task-parent")
        let console = try XCTUnwrap(ledger.console(for: "env-dup"))

        // Identical argv on both clients: nothing caller-supplied is unique.
        async let first = registry.run(
            environmentID: "env-dup", argv: ["/bin/sh", "-c", "echo call_1"],
            workingDirectory: nil, standardInput: nil,
            timeout: 10, maxOutputBytes: 4096, cancellation: nil
        )
        async let second = registry.run(
            environmentID: "env-dup", argv: ["/bin/sh", "-c", "echo call_1"],
            workingDirectory: nil, standardInput: nil,
            timeout: 10, maxOutputBytes: 4096, cancellation: nil
        )
        let tokens = try await waitForExecCount(console, 2)
        XCTAssertEqual(Set(tokens).count, 2, "each execution mints its own transport token")
        let (firstResult, secondResult) = try await (first, second)
        XCTAssertEqual(
            Set([firstResult.stdout, secondResult.stdout]),
            Set(tokens.map { "reply-\($0.prefix(4))" }),
            "each client keeps exactly its own token's output"
        )
    }

    /// One client's flood must not cost another client its completion: the
    /// bounded token stream drops payload first and always keeps control
    /// frames, including END.
    func testTokenStreamKeepsControlFramesWhileDroppingPayloadUnderPressure() async {
        let stream = LinuxGuestTokenStream(maxBufferedBytes: 64)
        await stream.pushControl(Data("\u{1e}FLOE-END token-1 0\u{1e}".utf8))
        for _ in 0..<8 {
            await stream.push(Data(repeating: 0x41, count: 32))
        }
        let counters = await stream.dropCounters()
        XCTAssertGreaterThan(counters.payloadBytes, 0, "payload beyond the bound must be dropped")
        XCTAssertEqual(counters.controlFrames, 0, "control frames must never be dropped")
        await stream.finish()
        var collected = Data()
        while let chunk = await stream.next() {
            collected.append(chunk)
        }
        XCTAssertTrue(String(decoding: collected, as: UTF8.self).contains("\u{1e}FLOE-END token-1 0\u{1e}"),
                      "the END frame survived the flood")
        XCTAssertLessThanOrEqual(collected.count, 64 + 32, "the retained payload stays bounded")
    }

    /// The bounded console refuses to silently skip bytes: an overflow is
    /// recorded and the stream is finished so every client fails honestly.
    func testConsoleSinkOverflowFailsClosedInsteadOfSilentlyDroppingBytes() {
        var continuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(2)) { continuation = $0 }
        let sink = TinyEMUConsoleSink(continuation: continuation)
        for index in 0..<5 {
            sink.append(Data("chunk-\(index)".utf8))
        }
        XCTAssertGreaterThan(sink.overflowedChunks, 0, "the refused chunk must be recorded")

        let collector = StringCollector()
        let expectation = expectation(description: "stream finished")
        let streamCopy = stream
        Task {
            for await chunk in streamCopy {
                collector.append(String(decoding: chunk, as: UTF8.self))
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(collector.values, ["chunk-0", "chunk-1"],
                       "the bounded console keeps the oldest queued chunks and then closes honestly")
    }

    /// A run's `environment` is applied to the guest command (the console
    /// protocol carries no env field), safely quoted, instead of being
    /// silently discarded.
    func testShellBackendAppliesPerRunEnvironmentToTheGuestCommand() async throws {
        let runner = CapturingLinuxRunner()
        let backend = LinuxGuestShellBackend(runner: runner)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-multiclient-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let request = ShellRunRequest(
            command: "printf '%s' \"$FLOE_MC_ONE\"",
            cwd: ".",
            rootURL: root,
            environment: ["FLOE_MC_ONE": "va'lue $HOME", "FLOE_MC_TWO": "two"],
            timeout: 5,
            maxOutputBytes: 1024,
            sessionID: "session-env",
            toolEnvironment: ToolEnvironment(id: "env-mc", writableLayerURL: root, layerURLs: [], variables: [:])
        )
        let outcome = await backend.run(request, cancellation: nil)
        guard case .exited(let code, _, _, _, _, _) = outcome else {
            return XCTFail("expected an exit outcome, got \(outcome)")
        }
        XCTAssertEqual(code, 0)
        let capturedArgv = await runner.lastArgv()
        let argv = try XCTUnwrap(capturedArgv)
        XCTAssertEqual(Array(argv.prefix(2)), ["/bin/sh", "-c"])
        let script = try XCTUnwrap(argv.last)
        XCTAssertTrue(script.contains("export FLOE_MC_ONE='va'\\''lue $HOME'"),
                      "values are exported verbatim (single-quote escaped): \(script)")
        XCTAssertTrue(script.contains("export FLOE_MC_TWO='two'"))
        XCTAssertTrue(script.hasSuffix("printf '%s' \"$FLOE_MC_ONE\""), "the client command stays last")
    }
}

/// Thread-safe string collector for the console-sink regression.
private final class StringCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ value: String) {
        lock.lock()
        items.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// Minimal scripted `LinuxCommandRunning` that records the argv it received.
private final class CapturingLinuxRunner: LinuxCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [[String]] = []

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
        record(argv)
        return LinuxCommandResult(stdout: "", stderr: "", exitCode: 0)
    }

    /// Synchronous helper: NSLock must not be taken in an async context.
    private func record(_ argv: [String]) {
        lock.lock()
        captured.append(argv)
        lock.unlock()
    }

    func lastArgv() -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        return captured.last
    }
}
