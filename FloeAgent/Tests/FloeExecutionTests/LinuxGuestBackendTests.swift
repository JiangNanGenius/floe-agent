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
    private var images: [String: LinuxGuestImage] = [:]
    private var sessionCounts: [String: Int] = [:]

    func record(environmentID: String, image: LinuxGuestImage, console: TestLinuxGuestConsole) {
        lock.lock()
        environments.append(environmentID)
        consoles[environmentID] = console
        images[environmentID] = image
        sessionCounts[environmentID, default: 0] += 1
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

    /// The exact image the registry handed to the session factory — capture
    /// point for the engine-path contract.
    func image(for environmentID: String) -> LinuxGuestImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[environmentID]
    }

    func sessionCount(for environmentID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return sessionCounts[environmentID, default: 0]
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
        ledger.record(environmentID: descriptor.id, image: image, console: console)
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

// MARK: - Runtime boot paths and per-environment disks

/// A small on-disk qualified image: real files, real digests, relative
/// manifest paths — exactly the shape the production resolver verifies.
private struct RuntimeImageFixture {
    var root: URL
    var id: String
    var manifest: LinuxGuestImage
    var biosURL: URL
    var kernelURL: URL
    var initrdURL: URL
    var diskURL: URL
    var diskBytes: Data

    var imageDirectory: URL { root.appendingPathComponent(id, isDirectory: true) }

    var diskDigest: String {
        manifest.artifactDigest(role: .disk)?.sha512 ?? "-"
    }
}

private func makeTemporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeRuntimeImageFixture(
    name: String,
    id: String = "floe-runtime-test",
    diskBytes: Data = Data(repeating: 0xA1, count: 8 * 1024)
) throws -> RuntimeImageFixture {
    let root = try makeTemporaryDirectory("runtime-images-\(name)")
    let directory = root.appendingPathComponent(id, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let biosBytes = Data("bios-\(name)".utf8)
    let kernelBytes = Data("kernel-\(name)".utf8)
    let initrdBytes = Data("initrd-\(name)".utf8)
    let bios = directory.appendingPathComponent("bbl64.bin")
    let kernel = directory.appendingPathComponent("kernel-riscv64.bin")
    let initrd = directory.appendingPathComponent("initrd.img")
    let disk = directory.appendingPathComponent("disk.img")
    try biosBytes.write(to: bios)
    try kernelBytes.write(to: kernel)
    try initrdBytes.write(to: initrd)
    try diskBytes.write(to: disk)
    let manifest = LinuxGuestImage(
        id: id,
        biosPath: "bbl64.bin",
        kernelPath: "kernel-riscv64.bin",
        initrdPath: "initrd.img",
        diskPath: "disk.img",
        diskReadWrite: true,
        cmdline: "console=hvc0 root=/dev/vda rw",
        qualified: true,
        qualificationEvidence: "runtime path test \(name)",
        qualificationRun: "run-\(name)",
        artifacts: [
            LinuxGuestImageArtifact(role: .bios, path: "bbl64.bin", sha512: FloeDigest.sha512Hex(biosBytes), bytes: Int64(biosBytes.count)),
            LinuxGuestImageArtifact(role: .kernel, path: "kernel-riscv64.bin", sha512: FloeDigest.sha512Hex(kernelBytes), bytes: Int64(kernelBytes.count)),
            LinuxGuestImageArtifact(role: .initrd, path: "initrd.img", sha512: FloeDigest.sha512Hex(initrdBytes), bytes: Int64(initrdBytes.count)),
            LinuxGuestImageArtifact(role: .disk, path: "disk.img", sha512: FloeDigest.sha512Hex(diskBytes), bytes: Int64(diskBytes.count)),
        ]
    )
    try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
    return RuntimeImageFixture(
        root: root,
        id: id,
        manifest: manifest,
        biosURL: bios,
        kernelURL: kernel,
        initrdURL: initrd,
        diskURL: disk,
        diskBytes: diskBytes
    )
}

private func resolvedPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
}

private func runtimeDiskDirectory(writable: URL, environmentID: String) -> URL {
    writable
        .appendingPathComponent(LinuxGuestRuntimeImagePreparer.writableDirectoryName, isDirectory: true)
        .appendingPathComponent("disks", isDirectory: true)
        .appendingPathComponent(environmentID, isDirectory: true)
}

private func stagingFiles(under writable: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(at: writable, includingPropertiesForKeys: nil) else { return [] }
    return enumerator.compactMap { ($0 as? URL)?.lastPathComponent }.filter { $0.contains(".staging-") }
}

/// Deterministic cancellation gate: the preparation task waits until the test
/// has cancelled it, so `Task.checkCancellation()` inside the preparer is
/// guaranteed to run against a cancelled task.
private actor RuntimeCheckGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

final class LinuxGuestRuntimeImageTests: XCTestCase {
    private func makeRegistry(
        fixture: RuntimeImageFixture,
        descriptors: [String: LinuxGuestEnvironmentDescriptor],
        ledger: FakeSessionLedger
    ) -> TinyEMULinuxGuestRegistry {
        TinyEMULinuxGuestRegistry(
            environments: FakeEnvironmentProvider(descriptors: descriptors),
            images: FileLinuxGuestImageResolver(root: fixture.root),
            limits: .standard,
            factory: FakeSessionFactory(ledger: ledger) { _, token in reply(token) }
        )
    }

    func testStartResolvesAbsoluteVerifiedBootFilesAndPrivateDisk() async throws {
        let fixture = try makeRuntimeImageFixture(name: "absolute")
        let writable = try makeTemporaryDirectory("layer-absolute")
        let ledger = FakeSessionLedger()
        let registry = makeRegistry(
            fixture: fixture,
            descriptors: ["env-a": LinuxGuestEnvironmentDescriptor(id: "env-a", writableDirectory: writable, imageID: fixture.id)],
            ledger: ledger
        )

        let started = try await registry.start(environmentID: "env-a", taskID: nil)
        XCTAssertTrue(started)
        let captured = try XCTUnwrap(ledger.image(for: "env-a"), "the factory must receive the prepared image")

        XCTAssertTrue(captured.biosPath.hasPrefix("/"), "bios must be an absolute path, got \(captured.biosPath)")
        XCTAssertEqual(captured.biosPath, resolvedPath(fixture.biosURL))
        XCTAssertEqual(captured.kernelPath, resolvedPath(fixture.kernelURL))
        XCTAssertEqual(captured.initrdPath, resolvedPath(fixture.initrdURL))
        let diskPath = try XCTUnwrap(captured.diskPath)
        XCTAssertTrue(diskPath.hasPrefix(resolvedPath(writable) + "/"), "disk must live under the environment writable root, got \(diskPath)")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: diskPath)), fixture.diskBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: diskPath))
        // The verified base is the immutable verification source: starting an
        // environment must not touch it.
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: fixture.diskURL), fixture.diskDigest)

        let origin = runtimeDiskDirectory(writable: writable, environmentID: "env-a")
            .appendingPathComponent(LinuxGuestRuntimeImagePreparer.originFileName)
        let originText = String(decoding: try Data(contentsOf: origin), as: UTF8.self)
        XCTAssertTrue(originText.contains(fixture.id), "origin sidecar must record the source image id")
        XCTAssertTrue(originText.contains(String(fixture.diskDigest.prefix(32))), "origin sidecar must record the verified base digest")
    }

    func testRestartReusesModifiedDiskAndKeepsVerifiedBase() async throws {
        let fixture = try makeRuntimeImageFixture(name: "restart")
        let writable = try makeTemporaryDirectory("layer-restart")
        let ledger = FakeSessionLedger()
        let registry = makeRegistry(
            fixture: fixture,
            descriptors: ["env-a": LinuxGuestEnvironmentDescriptor(id: "env-a", writableDirectory: writable, imageID: fixture.id)],
            ledger: ledger
        )

        _ = try await registry.start(environmentID: "env-a", taskID: nil)
        let firstDisk = try XCTUnwrap(ledger.image(for: "env-a")?.diskPath)
        // Simulate guest package state written to the environment disk.
        let marker = Data("apt-state".utf8)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: firstDisk))
        handle.seekToEndOfFile()
        handle.write(marker)
        try handle.close()
        await registry.stop(environmentID: "env-a")

        _ = try await registry.start(environmentID: "env-a", taskID: nil)
        XCTAssertEqual(ledger.sessionCount(for: "env-a"), 2)
        let secondDisk = try XCTUnwrap(ledger.image(for: "env-a")?.diskPath)
        XCTAssertEqual(secondDisk, firstDisk, "a restart must reuse the environment disk")
        let contents = try Data(contentsOf: URL(fileURLWithPath: secondDisk))
        XCTAssertEqual(contents.count, fixture.diskBytes.count + marker.count, "a restart must not re-copy the base over the mutated disk")
        XCTAssertEqual(contents.suffix(marker.count), marker)
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: fixture.diskURL), fixture.diskDigest)
        XCTAssertTrue(stagingFiles(under: writable).isEmpty)
    }

    func testEnvironmentsGetSeparateDisksEvenInOneWritableLayer() async throws {
        let fixture = try makeRuntimeImageFixture(name: "isolation")
        let shared = try makeTemporaryDirectory("layer-shared")
        let ledger = FakeSessionLedger()
        let registry = makeRegistry(
            fixture: fixture,
            descriptors: [
                "env-a": LinuxGuestEnvironmentDescriptor(id: "env-a", writableDirectory: shared, imageID: fixture.id),
                "env-b": LinuxGuestEnvironmentDescriptor(id: "env-b", writableDirectory: shared, imageID: fixture.id),
            ],
            ledger: ledger
        )

        _ = try await registry.start(environmentID: "env-a", taskID: nil)
        let diskA = try XCTUnwrap(ledger.image(for: "env-a")?.diskPath)
        let marker = Data("env-a-apt-state".utf8)
        try marker.write(to: URL(fileURLWithPath: diskA), options: [])
        await registry.stop(environmentID: "env-a")

        _ = try await registry.start(environmentID: "env-b", taskID: nil)
        let diskB = try XCTUnwrap(ledger.image(for: "env-b")?.diskPath)
        XCTAssertNotEqual(diskA, diskB, "different environments must not share one writable disk")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: diskB)), fixture.diskBytes, "env-b must start from the base, not env-a's edits")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: diskA)), marker, "env-a's disk must keep its own state")
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: fixture.diskURL), fixture.diskDigest)
    }

    func testStartWithoutWritableRootIsRejectedExplicitly() async throws {
        let fixture = try makeRuntimeImageFixture(name: "no-root")
        let ledger = FakeSessionLedger()
        let registry = makeRegistry(
            fixture: fixture,
            // writableDirectory == nil: the production path must refuse
            // instead of preparing a disk in some temporary directory.
            descriptors: ["env-a": LinuxGuestEnvironmentDescriptor(id: "env-a", imageID: fixture.id)],
            ledger: ledger
        )

        do {
            _ = try await registry.start(environmentID: "env-a", taskID: nil)
            XCTFail("starting without a writable root must fail")
        } catch let error as LinuxGuestRuntimeImageError {
            guard case .writableRootMissing = error else { return XCTFail("unexpected error \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertNil(ledger.image(for: "env-a"), "no VM session may be created without a writable root")
        XCTAssertEqual(try FloeDigest.sha512Hex(ofFileAt: fixture.diskURL), fixture.diskDigest)
    }

    func testUpdatedVerifiedBaseConflictsInsteadOfOverwritingEnvironmentDisk() async throws {
        let fixture = try makeRuntimeImageFixture(name: "update")
        let writable = try makeTemporaryDirectory("layer-update")
        let ledger = FakeSessionLedger()
        let registry = makeRegistry(
            fixture: fixture,
            descriptors: ["env-a": LinuxGuestEnvironmentDescriptor(id: "env-a", writableDirectory: writable, imageID: fixture.id)],
            ledger: ledger
        )
        _ = try await registry.start(environmentID: "env-a", taskID: nil)
        let disk = try XCTUnwrap(ledger.image(for: "env-a")?.diskPath)
        let marker = Data("user-packages-preserved".utf8)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: disk))
        handle.seekToEndOfFile()
        handle.write(marker)
        try handle.close()
        await registry.stop(environmentID: "env-a")

        // A new qualification of the same image id installs different base
        // bytes under the same paths (a real image update/re-import).
        let updatedBytes = Data(repeating: 0xB2, count: 16 * 1024)
        try updatedBytes.write(to: fixture.diskURL)
        var updatedManifest = fixture.manifest
        updatedManifest.artifacts = updatedManifest.artifacts?.map { artifact in
            guard artifact.role == .disk else { return artifact }
            return LinuxGuestImageArtifact(
                role: .disk,
                path: artifact.path,
                sha512: FloeDigest.sha512Hex(updatedBytes),
                bytes: Int64(updatedBytes.count)
            )
        }
        try JSONEncoder().encode(updatedManifest).write(to: fixture.imageDirectory.appendingPathComponent("manifest.json"))

        do {
            _ = try await registry.start(environmentID: "env-a", taskID: nil)
            XCTFail("an updated verified base must not silently replace the environment disk")
        } catch let error as LinuxGuestRuntimeImageError {
            guard case .diskOriginConflict = error else { return XCTFail("unexpected error \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let preserved = try Data(contentsOf: URL(fileURLWithPath: disk))
        XCTAssertEqual(preserved.suffix(marker.count), marker, "the environment disk must keep its own state")
        XCTAssertEqual(preserved.count, fixture.diskBytes.count + marker.count)
        XCTAssertTrue(stagingFiles(under: writable).isEmpty)
    }

    func testCancelledPreparationKeepsDiskAndCleansStaging() async throws {
        let fixture = try makeRuntimeImageFixture(name: "cancel")
        let writable = try makeTemporaryDirectory("layer-cancel")
        let preparer = LinuxGuestRuntimeImagePreparer()
        let arguments = (fixture, writable, preparer)
        let diskURL = runtimeDiskDirectory(writable: writable, environmentID: "env-a").appendingPathComponent(LinuxGuestRuntimeImagePreparer.diskFileName)

        // First preparation succeeds and establishes the environment disk.
        _ = try preparer.prepare(
            image: fixture.manifest,
            imageDirectory: fixture.imageDirectory,
            environmentID: "env-a",
            writableDirectory: writable
        )
        let before = try Data(contentsOf: diskURL)

        let gate = RuntimeCheckGate()
        let task = Task { () -> LinuxGuestImage in
            await gate.wait()
            return try arguments.2.prepare(
                image: arguments.0.manifest,
                imageDirectory: arguments.0.imageDirectory,
                environmentID: "env-a",
                writableDirectory: arguments.1
            )
        }
        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("a cancelled preparation must throw")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: diskURL), before, "cancellation must not touch the existing environment disk")
        XCTAssertTrue(stagingFiles(under: writable).isEmpty)
    }

    func testFailedCopyCleansStagingAndLeavesNoDisk() async throws {
        let fixture = try makeRuntimeImageFixture(name: "copy-failure")
        let writable = try makeTemporaryDirectory("layer-copy-failure")
        let preparer = LinuxGuestRuntimeImagePreparer()
        // An unreadable base disk makes both the clone and the byte-copy path
        // fail after the staged origin exists, so the cleanup path runs.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.diskURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.diskURL.path) }

        do {
            _ = try preparer.prepare(
                image: fixture.manifest,
                imageDirectory: fixture.imageDirectory,
                environmentID: "env-a",
                writableDirectory: writable
            )
            XCTFail("an unreadable base disk must fail preparation")
        } catch is CancellationError {
            XCTFail("an unreadable base disk must not report cancellation")
        } catch {
            // expected: explicit preparation failure
        }
        XCTAssertTrue(stagingFiles(under: writable).isEmpty, "a failed copy must remove its staging files")
        let directory = runtimeDiskDirectory(writable: writable, environmentID: "env-a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(LinuxGuestRuntimeImagePreparer.diskFileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(LinuxGuestRuntimeImagePreparer.originFileName).path))
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
