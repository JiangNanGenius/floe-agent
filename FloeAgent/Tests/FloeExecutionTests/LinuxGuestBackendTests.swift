// FloeExecutionTests — Linux guest backend contract.
//
// These tests exercise the console framing, the command channel bounds and
// the registry's ownership/lifecycle rules with a scripted console. They do
// not need a guest image: the TinyEMU machine is replaced by the fake session
// factory, so the tests cover everything the app wires below the engine.

import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeExecution

// MARK: - Fakes

/// Scripted console. `handler` receives the command token and returns the
/// console chunks to emit for it.
final class TestLinuxGuestConsole: LinuxGuestConsoleTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<Data>.Continuation
    private let stream: AsyncStream<Data>
    private var handler: (@Sendable (String) -> [Data])?
    private var writtenBytes: [UInt8] = []

    init(handler: (@Sendable (String) -> [Data])? = nil) {
        var captured: AsyncStream<Data>.Continuation!
        self.stream = AsyncStream { captured = $0 }
        self.continuation = captured
        self.handler = handler
    }

    var written: [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return writtenBytes
    }

    func setHandler(_ handler: @escaping @Sendable (String) -> [Data]) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func output() async -> AsyncStream<Data> { stream }

    func write(_ bytes: [UInt8]) async throws {
        let handler = record(bytes)
        guard let token = Self.token(in: bytes), let handler else { return }
        for chunk in handler(token) {
            continuation.yield(chunk)
        }
    }

    /// Synchronous helper: NSLock must not be taken inside an async context.
    private func record(_ bytes: [UInt8]) -> (@Sendable (String) -> [Data])? {
        lock.lock()
        defer { lock.unlock() }
        writtenBytes.append(contentsOf: bytes)
        return handler
    }

    func close() async {
        continuation.finish()
    }

    static func token(in bytes: [UInt8]) -> String? {
        guard let text = String(bytes: bytes, encoding: .utf8),
              let range = text.range(of: "\u{1e}FLOE-EXEC ") else { return nil }
        return text[range.upperBound...].split(separator: " ").first.map(String.init)
    }
}

actor FakeSessionState {
    private(set) var running = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func didStart() { running = true; startCount += 1 }
    func didStop() { running = false; stopCount += 1 }
}

/// Records what the registry asked for while handing out fake sessions.
final class FakeSessionLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var environments: [String] = []
    private var consoles: [String: TestLinuxGuestConsole] = [:]

    func record(environmentID: String, console: TestLinuxGuestConsole) {
        lock.lock()
        environments.append(environmentID)
        consoles[environmentID] = console
        lock.unlock()
    }

    var createdEnvironments: [String] {
        lock.lock()
        defer { lock.unlock() }
        return environments
    }

    func console(for environmentID: String) -> TestLinuxGuestConsole? {
        lock.lock()
        defer { lock.unlock() }
        return consoles[environmentID]
    }
}

struct FakeSessionFactory: LinuxGuestSessionCreating {
    let ledger: FakeSessionLedger
    let handler: @Sendable (String, String) -> [Data]

    func makeSession(
        descriptor: LinuxGuestEnvironmentDescriptor,
        image: LinuxGuestImage,
        limits: LinuxGuestLimits
    ) throws -> LinuxGuestSessionHandle {
        let console = TestLinuxGuestConsole { token in
            handler(descriptor.id, token)
        }
        ledger.record(environmentID: descriptor.id, console: console)
        let state = FakeSessionState()
        return LinuxGuestSessionHandle(
            transport: console,
            start: { await state.didStart() },
            stop: { await state.didStop() },
            close: { await state.didStop() },
            isRunning: { await state.running },
            addForward: { _ in },
            removeForward: { _ in }
        )
    }
}

struct FakeEnvironmentProvider: LinuxGuestEnvironmentProviding {
    var descriptors: [String: LinuxGuestEnvironmentDescriptor]

    func linuxGuestEnvironment(id: String) async -> LinuxGuestEnvironmentDescriptor? {
        descriptors[id]
    }
}

struct FakeImageResolver: LinuxGuestImageResolving {
    var images: [String: LinuxGuestImage]

    func linuxGuestImage(id: String) async -> LinuxGuestImage? {
        images[id]
    }
}

private func makeDescriptor(id: String, imageID: String = "test-image") -> LinuxGuestEnvironmentDescriptor {
    LinuxGuestEnvironmentDescriptor(id: id, ownerID: "owner", imageID: imageID)
}

private func makeImage(qualified: Bool = true) -> LinuxGuestImage {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-linux-test-\(UUID().uuidString)", isDirectory: true)
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
        qualified: qualified,
        qualificationEvidence: qualified ? "native protocol check \(UUID().uuidString)" : nil,
        qualificationRun: qualified ? "run-test-1" : nil,
        artifacts: qualified ? artifacts : nil
    )
}

private func reply(_ token: String, stdout: String = "hi", stderr: String = "oops", exit: Int32 = 0) -> [Data] {
    var data = Data()
    data.append(Data("\u{1e}FLOE-BEGIN \(token)\u{1e}\u{1e}FLOE-OUT \(token)\u{1e}".utf8))
    data.append(Data(stdout.utf8))
    data.append(Data("\u{1e}FLOE-ERR \(token)\u{1e}".utf8))
    data.append(Data(stderr.utf8))
    data.append(Data("\u{1e}FLOE-END \(token) \(exit)\u{1e}".utf8))
    return [data]
}

// MARK: - Framing

final class LinuxGuestFramingTests: XCTestCase {
    func testExecFramesCarryChunkedPayload() throws {
        let payload = LinuxGuestFraming.payload(
            of: ["apt-get", "update"],
            workingDirectory: "/root",
            standardInput: "stdin"
        )
        XCTAssertGreaterThan(payload.count, 0)
        let frames = LinuxGuestFraming.payloadHeader("EXEC", token: "T1", payload: payload)
        let text = frames.map { String(decoding: $0, as: UTF8.self) }
        XCTAssertTrue(text.first?.hasPrefix("\u{1e}FLOE-EXEC T1 ") == true)
        XCTAssertTrue(text.last?.contains("FLOE-RUN T1") == true)
        let chunks = text.dropFirst().dropLast().compactMap { line -> String? in
            guard let range = line.range(of: "FLOE-CHUNK T1 ") else { return nil }
            let body = line[range.upperBound...].replacingOccurrences(of: "\u{1e}", with: "")
            return body.split(separator: " ").dropFirst().first.map(String.init)
        }
        XCTAssertEqual(Data(base64Encoded: chunks.joined(), options: .ignoreUnknownCharacters), payload)
    }

    func testSessionParserStreamsRawOutputAndExit() {
        var parser = LinuxGuestFraming.SessionParser(sessionID: "S1")
        let frames = Data("\u{1e}FLOE-OUT S1\u{1e}hello \u{1e}FLOE-END S1 3\u{1e}".utf8)
        guard case .outputAndFinished(let data, let exit) = parser.feed(frames) else {
            return XCTFail("session parser did not finish")
        }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello ")
        XCTAssertEqual(exit, 3)
    }

    func testParserHandlesSplitMarkersAndSections() {
        var parser = LinuxGuestFraming.Parser(token: "T2", maxOutputBytes: 1024)
        let full = Data("""
        \u{1e}FLOE-BEGIN T2\u{1e}\u{1e}FLOE-OUT T2\u{1e}out-1\u{1e}FLOE-ERR T2\u{1e}err-1\u{1e}FLOE-END T2 7\u{1e}
        """.utf8)
        // Feed in two halves so every marker boundary is split.
        let midpoint = full.index(full.startIndex, offsetBy: full.count / 2)
        XCTAssertEqual(parser.feed(Data(full[..<midpoint])), .needMore)
        guard case .finished(let code) = parser.feed(Data(full[midpoint...])) else {
            return XCTFail("parser did not finish")
        }
        XCTAssertEqual(code, 7)
        XCTAssertEqual(parser.stdoutText, "out-1")
        XCTAssertEqual(parser.stderrText, "err-1")
    }

    func testParserDiscardsPreludeAndBoundsOutput() {
        var parser = LinuxGuestFraming.Parser(token: "T3", maxOutputBytes: 4)
        _ = parser.feed(Data("boot log noise".utf8))
        _ = parser.feed(Data("\u{1e}FLOE-BEGIN T3\u{1e}\u{1e}FLOE-OUT T3\u{1e}".utf8))
        _ = parser.feed(Data("0123456789".utf8))
        guard case .finished(let code) = parser.feed(Data("\u{1e}FLOE-END T3 0\u{1e}".utf8)) else {
            return XCTFail("parser did not finish")
        }
        XCTAssertEqual(code, 0)
        XCTAssertEqual(parser.stdoutText, "0123")
        XCTAssertTrue(parser.truncated)
        XCTAssertFalse(parser.stdoutText.contains("boot log"))
    }
}

// MARK: - Command channel

final class LinuxGuestCommandChannelTests: XCTestCase {
    func testRunCollectsStdoutStderrAndExit() async throws {
        let console = TestLinuxGuestConsole()
        console.setHandler { token in reply(token) }
        let channel = LinuxGuestCommandChannel(transport: console)
        let result = try await channel.run(argv: ["dpkg-query", "-W"], timeout: 5)
        XCTAssertEqual(result.stdout, "hi")
        XCTAssertEqual(result.stderr, "oops")
        XCTAssertEqual(result.exitCode, 0)
        let text = String(decoding: console.written, as: UTF8.self)
        XCTAssertTrue(text.contains("\u{1e}FLOE-EXEC "))
    }

    func testSequentialCommandsShareOneConsoleReader() async throws {
        let console = TestLinuxGuestConsole()
        console.setHandler { token in reply(token, stdout: token, stderr: "", exit: 0) }
        let channel = LinuxGuestCommandChannel(transport: console)
        let first = try await channel.run(argv: ["/bin/echo", "1"], timeout: 5)
        let second = try await channel.run(argv: ["/bin/echo", "2"], timeout: 5)
        XCTAssertEqual(first.exitCode, 0)
        XCTAssertEqual(second.exitCode, 0)
        XCTAssertEqual(first.stdout, "T1")
        XCTAssertEqual(second.stdout, "T2")
    }

    func testRunTimesOutAndPoisonsTheChannel() async throws {
        let console = TestLinuxGuestConsole()
        console.setHandler { _ in [] }
        let channel = LinuxGuestCommandChannel(transport: console)
        do {
            _ = try await channel.run(argv: ["sleep", "100"], timeout: 0.2)
            XCTFail("expected a timeout")
        } catch let error as LinuxGuestError {
            guard case .timedOut = error else { return XCTFail("unexpected error \(error)") }
        }
        let poisoned = await channel.isPoisoned
        XCTAssertTrue(poisoned)
        XCTAssertTrue(console.written.contains(0x03), "timeout must interrupt the guest command")
    }

    func testRunCancellationInterrupts() async throws {
        let console = TestLinuxGuestConsole()
        console.setHandler { _ in [] }
        let channel = LinuxGuestCommandChannel(transport: console)
        let token = CancellationToken()
        let task = Task {
            try await channel.run(argv: ["sleep", "100"], timeout: 10, cancellation: token)
        }
        try await Task.sleep(for: .milliseconds(150))
        token.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch FloeError.cancelled {
            // expected
        }
        let poisoned = await channel.isPoisoned
        XCTAssertTrue(poisoned)
        XCTAssertTrue(console.written.contains(0x03))
    }
}

// MARK: - Registry

final class LinuxGuestRegistryTests: XCTestCase {
    private func makeRegistry(
        descriptors: [String: LinuxGuestEnvironmentDescriptor],
        images: [String: LinuxGuestImage],
        factory: FakeSessionFactory
    ) -> TinyEMULinuxGuestRegistry {
        TinyEMULinuxGuestRegistry(
            environments: FakeEnvironmentProvider(descriptors: descriptors),
            images: FakeImageResolver(images: images),
            limits: .standard,
            factory: factory
        )
    }

    func testOwnsStoppedGuestButSupportsOnlyRunning() async {
        let ledger = FakeSessionLedger()
        let factory = FakeSessionFactory(ledger: ledger) { _, token in reply(token) }
        let registry = makeRegistry(
            descriptors: ["env-1": makeDescriptor(id: "env-1")],
            images: ["test-image": makeImage()],
            factory: factory
        )
        let owns = await registry.owns(environmentID: "env-1")
        let supports = await registry.supports(environmentID: "env-1")
        XCTAssertTrue(owns)
        XCTAssertFalse(supports)

        let unknownOwns = await registry.owns(environmentID: "env-other")
        XCTAssertFalse(unknownOwns)
    }

    func testStartRejectsUnqualifiedImage() async {
        let ledger = FakeSessionLedger()
        let factory = FakeSessionFactory(ledger: ledger) { _, token in reply(token) }
        let registry = makeRegistry(
            descriptors: ["env-1": makeDescriptor(id: "env-1")],
            images: ["test-image": makeImage(qualified: false)],
            factory: factory
        )
        do {
            _ = try await registry.start(environmentID: "env-1", taskID: nil)
            XCTFail("unqualified image must not start")
        } catch let error as LinuxGuestError {
            guard case .imageNotQualified = error else { return XCTFail("unexpected error \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let running = await registry.status(environmentID: "env-1").running
        XCTAssertFalse(running)
        XCTAssertTrue(ledger.createdEnvironments.isEmpty)
    }

    func testLifecycleRunsCommandsAndStops() async throws {
        let ledger = FakeSessionLedger()
        let factory = FakeSessionFactory(ledger: ledger) { _, token in reply(token, stdout: "ok", stderr: "", exit: 0) }
        let registry = makeRegistry(
            descriptors: ["env-1": makeDescriptor(id: "env-1")],
            images: ["test-image": makeImage()],
            factory: factory
        )
        let started = try await registry.start(environmentID: "env-1", taskID: "task-1")
        XCTAssertTrue(started)
        let supports = await registry.supports(environmentID: "env-1")
        XCTAssertTrue(supports)

        let result = try await registry.run(
            environmentID: "env-1",
            argv: ["apt-get", "update"],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 5,
            maxOutputBytes: 4096,
            cancellation: nil
        )
        XCTAssertEqual(result.stdout, "ok")
        XCTAssertEqual(result.exitCode, 0)

        await registry.stop(taskID: "task-1")
        let running = await registry.status(environmentID: "env-1").running
        XCTAssertFalse(running)
    }

    func testSecondGuestIsRejectedWhileOneRuns() async throws {
        let ledger = FakeSessionLedger()
        let factory = FakeSessionFactory(ledger: ledger) { _, token in reply(token) }
        let registry = makeRegistry(
            descriptors: [
                "env-1": makeDescriptor(id: "env-1"),
                "env-2": makeDescriptor(id: "env-2"),
            ],
            images: ["test-image": makeImage()],
            factory: factory
        )
        _ = try await registry.start(environmentID: "env-1", taskID: nil)
        do {
            _ = try await registry.start(environmentID: "env-2", taskID: nil)
            XCTFail("the engine supports one running guest at a time")
        } catch let error as LinuxGuestError {
            guard case .guestBusy = error else { return XCTFail("unexpected error \(error)") }
        }
        await registry.stop(environmentID: "env-1")
    }

    func testRunBeforeStartReportsNotRunning() async {
        let ledger = FakeSessionLedger()
        let factory = FakeSessionFactory(ledger: ledger) { _, token in reply(token) }
        let registry = makeRegistry(
            descriptors: ["env-1": makeDescriptor(id: "env-1")],
            images: ["test-image": makeImage()],
            factory: factory
        )
        do {
            _ = try await registry.run(
                environmentID: "env-1",
                argv: ["true"],
                workingDirectory: nil,
                standardInput: nil,
                timeout: 1,
                maxOutputBytes: 1024,
                cancellation: nil
            )
            XCTFail("expected notRunning")
        } catch let error as LinuxGuestError {
            guard case .notRunning = error else { return XCTFail("unexpected error \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

// MARK: - Shell routing backend

final class LinuxGuestShellBackendTests: XCTestCase {
    func testOwnedStoppedEnvironmentFailsInsteadOfRunning() async {
        let service = TinyEMULinuxCommandService(registry: TinyEMULinuxGuestRegistry(
            environments: FakeEnvironmentProvider(descriptors: ["env-1": makeDescriptor(id: "env-1")]),
            images: FakeImageResolver(images: [:]),
            limits: .standard,
            factory: FakeSessionFactory(ledger: FakeSessionLedger()) { _, token in reply(token) }
        ))
        let backend = LinuxGuestShellBackend(runner: service)
        let request = ShellRunRequest(
            command: "python3 -V",
            cwd: ".",
            rootURL: URL(fileURLWithPath: NSTemporaryDirectory()),
            sessionID: "session-1",
            toolEnvironment: ToolEnvironment(
                id: "env-1",
                writableLayerURL: URL(fileURLWithPath: NSTemporaryDirectory()),
                layerURLs: [],
                variables: [:]
            )
        )
        let outcome = await backend.run(request, cancellation: nil)
        guard case .failed(let message) = outcome else {
            return XCTFail("expected an honest failure, got \(outcome)")
        }
        XCTAssertTrue(message.contains("not running"), message)
    }

    func testStoppedGuestSessionsAreReported() async {
        let service = TinyEMULinuxCommandService(registry: TinyEMULinuxGuestRegistry(
            environments: FakeEnvironmentProvider(descriptors: [:]),
            images: FakeImageResolver(images: [:]),
            limits: .standard,
            factory: FakeSessionFactory(ledger: FakeSessionLedger()) { _, token in reply(token) }
        ))
        let backend = LinuxGuestShellBackend(runner: service)
        do {
            _ = try await backend.openSession(
                ShellOpenRequest(
                    rootURL: URL(fileURLWithPath: NSTemporaryDirectory()),
                    sessionID: "session-1",
                    toolEnvironment: ToolEnvironment(
                        id: "env-1",
                        writableLayerURL: URL(fileURLWithPath: NSTemporaryDirectory()),
                        layerURLs: [],
                        variables: [:]
                    )
                ),
                cancellation: nil
            )
            XCTFail("a stopped guest must not open an interactive session")
        } catch let error as LinuxGuestError {
            guard case .notRunning = error else { return XCTFail("unexpected error \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

// MARK: - Host/guest path mapping

final class LinuxGuestPathMapTests: XCTestCase {
    func testMapsPathsInsideSharesAndRejectsEscapes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-map-\(UUID().uuidString)", isDirectory: true)
        let layer = root.appendingPathComponent("layer", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let map = LinuxGuestPathMap(shares: [
            LinuxGuestShare(tag: LinuxGuestShare.environmentTag, hostDirectory: layer),
            LinuxGuestShare(tag: LinuxGuestShare.workspaceTag, hostDirectory: workspace),
        ])
        XCTAssertEqual(
            map.guestPath(forHostPath: workspace.appendingPathComponent("src/main.py").path),
            "/workspace/src/main.py"
        )
        XCTAssertEqual(map.guestPath(forHostPath: layer.path), "/floe/env")
        XCTAssertNil(map.guestPath(forHostPath: "/etc/passwd"))
        XCTAssertNil(map.guestPath(forHostPath: workspace.appendingPathComponent("../escape").path))
        XCTAssertEqual(
            map.hostPath(forGuestPath: "/floe/env/python/venv"),
            layer.appendingPathComponent("python/venv")
        )
        XCTAssertNil(map.hostPath(forGuestPath: "/etc/passwd"))
        XCTAssertEqual(map.environmentGuestRoot, "/floe/env")
        XCTAssertEqual(map.workspaceGuestRoot, "/workspace")
    }
}

// MARK: - Image verification and import

final class LinuxGuestImageStoreTests: XCTestCase {
    func testQualifiedFlagWithoutDigestsIsNotTrusted() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-flag-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bios = directory.appendingPathComponent("bbl64.bin")
        FileManager.default.createFile(atPath: bios.path, contents: Data("bios".utf8))
        let flagOnly = LinuxGuestImage(id: "flag-only", biosPath: bios.path, qualified: true, qualificationEvidence: "user wrote true")
        XCTAssertNotNil(flagOnly.qualificationFailure(), "a hand-written qualified flag without a run/digests must not start")
    }

    func testImportDirectoryVerifiesDigestsAndDetectsTampering() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-images-\(UUID().uuidString)", isDirectory: true)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let contents = Data("bios-bytes".utf8)
        try contents.write(to: source.appendingPathComponent("bbl64.bin"))
        let manifest = LinuxGuestImage(
            id: "floe-test",
            biosPath: "bbl64.bin",
            diskReadWrite: false,
            cmdline: "console=hvc0 root=/dev/vda rw",
            qualified: true,
            qualificationEvidence: "import test",
            qualificationRun: "run-local-1",
            artifacts: [
                LinuxGuestImageArtifact(role: .bios, path: "bbl64.bin", sha512: FloeDigest.sha512Hex(contents), bytes: Int64(contents.count))
            ]
        )
        try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("manifest.json"))

        let service = LinuxGuestImageInstallationService(root: root)
        let imported = try await service.importDirectory(at: source)
        XCTAssertEqual(imported.id, "floe-test")
        var status = await service.status(id: "floe-test")
        XCTAssertTrue(status.installed)
        XCTAssertNil(status.verificationFailure)
        XCTAssertFalse(status.distributable, "a local import is never a downloadable Floe image")

        // Rewriting the artifact must invalidate the digest check.
        try Data("tampered".utf8).write(to: service.imagesDirectory.appendingPathComponent("floe-test/bbl64.bin"))
        status = await service.status(id: "floe-test")
        XCTAssertNotNil(status.verificationFailure)
    }

    func testTrustedInstallRefusesAnUnpinnedImageID() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-images-\(UUID().uuidString)", isDirectory: true)
        let service = LinuxGuestImageInstallationService(root: root)
        do {
            _ = try await service.installTrustedImage(id: "floe-linux-base", downloader: NoopImageDownloader())
            XCTFail("the requested image ID has no pinned archive")
        } catch let error as LinuxGuestImageInstallError {
            guard case .noDistributableImage = error else { return XCTFail("unexpected error \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

private struct NoopImageDownloader: LinuxGuestImageDownloading {
    func download(_ url: URL, to destination: URL, maxBytes: Int64) async throws {
        throw LinuxGuestImageInstallError.downloadFailed("not used")
    }
}

// MARK: - Control frames and service supervisor

final class LinuxGuestControlFrameTests: XCTestCase {
    func testExecKeepsInlineFastPathAndChunksLargePayloads() {
        let small = LinuxGuestFraming.payload(of: ["true"], workingDirectory: nil, standardInput: nil)
        let smallFrames = LinuxGuestFraming.payloadFrames(name: "EXEC", token: "T", payload: small)
        XCTAssertEqual(smallFrames.count, 1)
        XCTAssertTrue(String(decoding: smallFrames[0], as: UTF8.self).hasPrefix("\u{1e}FLOE-EXEC T "))

        let large = LinuxGuestFraming.payload(
            of: ["/bin/sh", "-c", String(repeating: "x", count: 8_000)],
            workingDirectory: nil,
            standardInput: nil
        )
        let largeFrames = LinuxGuestFraming.payloadFrames(name: "EXEC", token: "T", payload: large)
        XCTAssertGreaterThan(largeFrames.count, 1)
        XCTAssertTrue(String(decoding: largeFrames.last!, as: UTF8.self).contains("FLOE-RUN T"))
    }

    func testSpawnAndOpenAlwaysUseTheChunkedEnvelope() {
        let payload = LinuxGuestFraming.servicePayload(of: ["true"], workingDirectory: nil, logPath: "/floe/env/services/job.log")
        let frames = LinuxGuestFraming.payloadFrames(name: "SPAWN", token: "T", payload: payload, allowInline: false)
        XCTAssertGreaterThan(frames.count, 1)
        XCTAssertTrue(String(decoding: frames[0], as: UTF8.self).contains("FLOE-SPAWN T "))
    }

    func testControlParserReadsPidAndExitAcrossChunks() {
        var parser = LinuxGuestFraming.ControlParser(token: "T")
        let full = Data("\u{1e}FLOE-PID T 4242\u{1e}\u{1e}FLOE-END T 0\u{1e}".utf8)
        let split = full.index(full.startIndex, offsetBy: 11)
        XCTAssertEqual(parser.feed(Data(full[..<split])), .needMore)
        guard case .finished(let exit) = parser.feed(Data(full[split...])) else {
            return XCTFail("control parser did not finish")
        }
        XCTAssertEqual(exit, 0)
        XCTAssertEqual(parser.pid, 4242)
    }
}

final class FakeServiceHost: LinuxGuestLocalServiceHosting, @unchecked Sendable {
    let lock = NSLock()
    private var alive = true
    private(set) var spawnedArgv: [String] = []
    private(set) var spawnedCwd: String?
    private(set) var spawnedLog: String?
    private(set) var killed: [Int32] = []
    private(set) var forwards: [LinuxGuestServiceForward] = []
    let descriptor: LinuxGuestEnvironmentDescriptor

    init(descriptor: LinuxGuestEnvironmentDescriptor) {
        self.descriptor = descriptor
    }

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
        let joined = argv.joined(separator: " ")
        if joined.contains("sysconfig.get_paths") {
            return LinuxCommandResult(stdout: "/floe/env/python/venv/lib/python3.12/site-packages\n", stderr: "", exitCode: 0)
        }
        if joined.contains("command -v python3") { return LinuxCommandResult(stdout: "python-ok\n", stderr: "", exitCode: 0) }
        if joined.contains("bin/pip") { return LinuxCommandResult(stdout: "pip-ok\n", stderr: "", exitCode: 0) }
        if joined.contains("--version") { return LinuxCommandResult(stdout: "Python 3.12.5\n", stderr: "", exitCode: 0) }
        return LinuxCommandResult(stdout: "", stderr: "", exitCode: 0)
    }

    func guestDescriptor(environmentID: String) async -> LinuxGuestEnvironmentDescriptor? { descriptor }

    func guestSpawn(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        logPath: String,
        timeout: TimeInterval,
        cancellation: CancellationToken?
    ) async throws -> Int32 {
        lock.withLock {
            spawnedArgv = argv
            spawnedCwd = workingDirectory
            spawnedLog = logPath
        }
        return 4242
    }

    func guestServiceAlive(environmentID: String, pid: Int32, timeout: TimeInterval) async throws -> Bool {
        lock.withLock { alive }
    }

    func guestKillService(environmentID: String, pid: Int32, timeout: TimeInterval) async throws -> Bool {
        lock.withLock {
            killed.append(pid)
            let wasAlive = alive
            alive = false
            return wasAlive
        }
    }

    func guestEnsureForward(environmentID: String, forward: LinuxGuestServiceForward) async throws {
        lock.withLock { forwards.append(forward) }
    }

    func guestRemoveForward(environmentID: String, forward: LinuxGuestServiceForward) async {
        lock.withLock { forwards.removeAll { $0 == forward } }
    }
}

final class LinuxGuestLocalServiceSupervisorTests: XCTestCase {
    func testSpawnUsesSharedVenvMappedPathsAndForwards() async throws {
        let environmentID = "env-service-\(UUID().uuidString)"
        let layer = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-svc-\(UUID().uuidString)", isDirectory: true)
        let services = layer.appendingPathComponent("services", isDirectory: true)
        try FileManager.default.createDirectory(at: services, withIntermediateDirectories: true)
        let entry = layer.appendingPathComponent("app.py")
        try Data("print('hi')".utf8).write(to: entry)
        let log = services.appendingPathComponent("job.log")
        try Data("log line\n".utf8).write(to: log)

        let descriptor = LinuxGuestEnvironmentDescriptor(
            id: environmentID,
            shares: [LinuxGuestShare(tag: LinuxGuestShare.environmentTag, hostDirectory: layer)],
            imageID: "test-image"
        )
        let host = FakeServiceHost(descriptor: descriptor)
        let supervisor = LinuxGuestLocalServiceSupervisor(host: host)
        defer { Task { await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID) } }

        let handle = try await supervisor.startLocalService(
            environmentID: environmentID,
            request: LinuxGuestLocalServiceRequest(
                entry: entry.path,
                runtime: .python,
                arguments: ["--flag"],
                workingDirectory: layer.path,
                port: 8123,
                logFile: log,
                environment: ["FOO": "bar"]
            ),
            cancellation: nil
        )
        XCTAssertEqual(handle.pid, 4242)
        XCTAssertEqual(host.spawnedCwd, "/floe/env")
        XCTAssertEqual(host.spawnedLog, "/floe/env/services/job.log")
        XCTAssertTrue(host.spawnedArgv.contains("PORT=8123"), host.spawnedArgv.joined(separator: " "))
        XCTAssertTrue(host.spawnedArgv.contains("FOO=bar"))
        XCTAssertTrue(host.spawnedArgv.contains("/floe/env/app.py"))
        XCTAssertEqual(handle.forward, LinuxGuestServiceForward(hostAddress: "127.0.0.1", hostPort: 8123, guestPort: 8123))
        XCTAssertEqual(host.forwards.count, 1)

        let running = await supervisor.localServiceSnapshot(handle)
        XCTAssertEqual(running.state, "running")
        XCTAssertEqual(running.stdout, "log line\n")

        await supervisor.stopLocalService(handle)
        XCTAssertEqual(host.killed, [4242])
        XCTAssertTrue(host.forwards.isEmpty)
    }

    func testWorkingDirectoryOutsideSharesIsAnError() async throws {
        let environmentID = "env-\(UUID().uuidString)"
        let layer = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-svc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: layer, withIntermediateDirectories: true)
        let entry = layer.appendingPathComponent("app.py")
        try Data("print('hi')".utf8).write(to: entry)
        let descriptor = LinuxGuestEnvironmentDescriptor(
            id: environmentID,
            shares: [LinuxGuestShare(tag: LinuxGuestShare.environmentTag, hostDirectory: layer)],
            imageID: "test-image"
        )
        let supervisor = LinuxGuestLocalServiceSupervisor(host: FakeServiceHost(descriptor: descriptor))
        do {
            _ = try await supervisor.startLocalService(
                environmentID: environmentID,
                request: LinuxGuestLocalServiceRequest(
                    entry: entry.path,
                    runtime: .node,
                    workingDirectory: "/etc",
                    port: 8124,
                    logFile: layer.appendingPathComponent("services/job.log")
                ),
                cancellation: nil
            )
            XCTFail("a working directory outside the shares must not silently fall back")
        } catch let error as LinuxGuestError {
            guard case .invalidConfiguration = error else { return XCTFail("unexpected error \(error)") }
        }
    }
}
