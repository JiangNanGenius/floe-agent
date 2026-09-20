// RunnerUpgradeCheck — focused existing-disk runner-upgrade check.
//
// Compiled by `runner_upgrade_check.sh` together with the *production*
// declarations that own the upgrade path (LinuxGuestImage qualification,
// LinuxGuestRuntimeImagePreparer, TinyEMULinuxGuestRegistry,
// LinuxGuestImageVerifier and the whole LinuxGuestCommandChannel), extracted
// verbatim and built with -swift-version 6. This check does not drive
// HostProtocolCheck or ChannelRouterCheck; it drives the registry exactly as
// the app does, against a scripted guest console, and asserts:
//
//   * a disk cloned from the manifest's declared predecessor origin is adopted
//     untouched (bytes, inode and origin.json) while the legacy runner inside
//     it is replaced in-guest from the verified standalone runner artifact;
//   * an unrelated disk origin is still a conflict and nothing is overwritten;
//   * missing / symlinked / wrong-size / wrong-digest runner bytes are
//     rejected before any replacement, with the disk preserved;
//   * the runner artifact obeys the shared structural/path/symlink/size/digest
//     checks with a distinct `runner` role (never `disk`);
//   * the legacy probe is a live HELLO probe with a finite timeout and the
//     ledger never substitutes for it;
//   * console reader ownership is single: production probe → legacy serial
//     channel → fresh production channel on the renewed post-reboot stream,
//     with the post-reboot CAPS verified before a session is registered;
//   * bounded admission refuses a duplicate concurrent start and a full guest
//     count/RAM budget without killing a running guest, and reservations are
//     released on failure and on stop.
//
// The only substituted declarations are the FloeCore/FloeTools seams
// (FloeDigest, FloeLogger, the distribution catalog). FloeDigest is a real
// SHA-512 implementation, so digests in this check match production bytes.

import Foundation

#if canImport(Darwin)
import Darwin
#endif

// The FloeCore/FloeTools seams and the production-factory stub are generated
// into the extracted module by runner_upgrade_check.sh; this file only adds
// the check harness around the real production declarations.

// MARK: - check recorder

enum CheckFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _passes = 0
    private var _failures: [String] = []

    var passes: Int {
        lock.lock()
        defer { lock.unlock() }
        return _passes
    }

    var failures: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _failures
    }

    func record(_ failure: String) {
        lock.lock()
        _failures.append(failure)
        lock.unlock()
    }

    func pass() {
        lock.lock()
        _passes += 1
        lock.unlock()
    }

    func check(_ label: String, _ body: () async throws -> Void) async {
        if ProcessInfo.processInfo.environment["FLOE_UPGRADE_DEBUG"] == "1" {
            FileHandle.standardError.write(Data("[check] \(label)\n".utf8))
        }
        do {
            try await body()
            pass()
        } catch {
            record("\(label): \(error)")
        }
    }

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String = "condition failed") throws {
        if !condition { throw CheckFailure.message(message()) }
    }
}

/// Times out one closure so a routing mistake fails the check instead of
/// hanging it (the process watchdog is the last resort, not the mechanism).
func withDeadline<T: Sendable>(
    _ seconds: TimeInterval,
    _ label: String,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            throw CheckFailure.message("\(label) did not finish within \(seconds)s")
        }
        guard let first = try await group.next() else {
            throw CheckFailure.message("\(label) produced no result")
        }
        group.cancelAll()
        return first
    }
}

// MARK: - scripted guest console

/// A scripted guest console transport. It plays the part of one TinyEMU VM:
/// a renewed output stream per boot, a runner that answers FLOE-HELLO only
/// when it speaks protocol 3, and a small in-memory guest filesystem that
/// executes the upgrade's /bin/sh steps.
final class ScriptedGuestTransport: LinuxGuestConsoleTransport, @unchecked Sendable {
    struct Configuration: Sendable {
        /// CAPS the runner already inside the disk answers (nil = legacy
        /// runner that never answers HELLO).
        var initialCaps: String?
        /// CAPS the runner answers after the in-guest replacement (nil =
        /// silent, i.e. the replacement did not produce a working runner).
        var postRebootCaps: String?
        /// The disk already boots a protocol-3 runner: no upgrade may run.
        var runnerAlreadyCurrent = false
        /// Make the 9p share copy fail so the console-upload fallback runs.
        var shareCopyFails = false
        /// Make the in-guest install script fail (digest checked by harness).
        var installRejects = false
        /// Delay the VM boot so a duplicate concurrent start can interleave.
        var bootDelayMilliseconds = 0
        /// The VM refuses to stop (the engine's stop budget elapsed and the
        /// run loop is still alive): the transport keeps reporting running
        /// until `allowStop()` is called.
        var refusesStop = false
    }

    let configuration: Configuration
    /// guest root → host directory, for the 9p shares this transport serves.
    private var shareRoots: [String: String] = [:]

    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private var stream: AsyncStream<Data>?
    private var running = false
    private var closed = false
    private var inbound = Data()
    private var assemblies: [String: (expected: Int, chunks: [Int: Data])] = [:]
    private var guestFiles: [String: Data] = [:]

    // Guest-visible state and observations.
    private var runnerInstalled = false
    private var installedDigest: String?
    private var refusesStop: Bool
    private(set) var outputRequests = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var closeCount = 0
    private(set) var shareCopyAttempts = 0
    private(set) var chunkCommands = 0
    private(set) var installScripts: [String] = []
    private(set) var stagedRunnerBytes: Data?
    private(set) var lastInstallError = ""
    private(set) var missingChunkAssemblies: [String] = []

    /// True when a second reader was handed the same live stream generation
    /// while the previous one was still registered (a stale-reader bug would
    /// surface here as the frame never reaching its owner, i.e. a timeout).
    private(set) var readerGenerations: [Int] = []
    private var generation = 0
    private var activeReaderGeneration: Int?

    init(configuration: Configuration) {
        self.configuration = configuration
        self.refusesStop = configuration.refusesStop
        // A TinyEMU machine creates its console stream at init and only
        // finishes it on close: the stream is NOT renewed across stop/start.
        makeStreamLocked()
    }

    /// Let a later stop attempt actually stop the VM (recovery path).
    func allowStop() {
        withLock { refusesStop = false }
    }

    func setShareRoots(guestToHost: [String: String]) {
        withLock { shareRoots = guestToHost }
    }

    var isRunning: Bool {
        withLock { running }
    }

    var generationCount: Int {
        withLock { generation }
    }

    // MARK: transport

    func write(_ bytes: [UInt8]) async throws {
        let frames = ingest(bytes)
        for frame in frames {
            await respond(to: frame)
        }
    }

    func close() async {
        await machineClose()
    }

    func output() async -> AsyncStream<Data> {
        withLock {
            outputRequests += 1
            readerGenerations.append(generation)
            activeReaderGeneration = generation
            return stream!
        }
    }

    /// Synchronous lock scope: NSLock is not usable directly in async
    /// contexts under Swift 6.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: machine lifecycle

    func machineStart() async throws {
        if configuration.bootDelayMilliseconds > 0 {
            try? await Task.sleep(for: .milliseconds(configuration.bootDelayMilliseconds))
        }
        debug("machineStart")
        withLock {
            // Same console stream as the running VM (production does not
            // finish the sink on stop, so the one router keeps reading across
            // a reboot). Only the guest's volatile state (tmpfs /tmp,
            // in-flight frames) is fresh after a boot.
            inbound.removeAll()
            assemblies.removeAll()
            guestFiles.removeAll()
            generation += 1
            startCount += 1
            running = true
        }
    }

    func machineStop() async {
        debug("machineStop refusesStop=\(withLock { refusesStop })")
        withLock {
            stopCount += 1
            // A refused stop leaves the VM alive: the engine's stop budget
            // elapsed while the run loop was still in a slice.
            if !refusesStop { running = false }
            // Not finishing the stream is the production behaviour and the
            // point of the single-reader design: the router survives the
            // reboot.
            inbound.removeAll()
            assemblies.removeAll()
        }
    }

    func machineClose() async {
        withLock {
            closeCount += 1
            // Production close() = stop() (may time out and keep the VM) then
            // sink.finish(): the stream ends even when the VM survives.
            if !refusesStop { running = false }
            closed = true
            continuation?.finish()
            continuation = nil
            stream = nil
        }
    }

    // MARK: frame handling

    private struct Frame {
        var name: String
        var token: String
        var arguments: String
    }

    private func makeStreamLocked() {
        var captured: AsyncStream<Data>.Continuation!
        let created = AsyncStream<Data>(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured
        stream = created
    }

    private func ingest(_ bytes: [UInt8]) -> [Frame] {
        lock.lock()
        inbound.append(contentsOf: bytes)
        var frames: [Frame] = []
        let marker = UInt8(0x1e)
        while true {
            guard let start = inbound.firstIndex(of: marker) else {
                inbound.removeAll(keepingCapacity: true)
                break
            }
            if start > inbound.startIndex {
                inbound.removeSubrange(inbound.startIndex..<start)
            }
            let after = inbound.index(after: inbound.startIndex)
            guard after < inbound.endIndex else { break }
            // Frame body ends at the next marker or newline.
            var end: Data.Index?
            var consumeThrough: Data.Index?
            var index = after
            while index < inbound.endIndex {
                if inbound[index] == marker {
                    end = index
                    let next = inbound.index(after: index)
                    consumeThrough = next
                    if next < inbound.endIndex, inbound[next] == 0x0a {
                        consumeThrough = inbound.index(after: next)
                    }
                    break
                }
                if inbound[index] == 0x0a {
                    end = index
                    consumeThrough = inbound.index(after: index)
                    break
                }
                index = inbound.index(after: index)
            }
            guard let bodyEnd = end, let consume = consumeThrough else { break }
            let body = Data(inbound[after..<bodyEnd])
            inbound.removeSubrange(inbound.startIndex..<consume)
            guard let text = String(data: body, encoding: .utf8), text.hasPrefix("FLOE-") else {
                continue
            }
            let remainder = text.dropFirst("FLOE-".count)
            let parts = remainder.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            frames.append(Frame(
                name: String(parts[0]),
                token: String(parts[1]),
                arguments: parts.count > 2 ? String(parts[2]) : ""
            ))
        }
        lock.unlock()
        return frames
    }

    private func respond(to frame: Frame) async {
        if ProcessInfo.processInfo.environment["FLOE_UPGRADE_DEBUG"] == "1" {
            FileHandle.standardError.write(Data("[harness] frame \(frame.name) caps=\(String(describing: currentCaps()))\n".utf8))
        }
        switch frame.name {
        case "HELLO":
            if let caps = currentCaps() {
                emit(Wire.caps(token: frame.token, capabilities: caps))
            }
            // A legacy runner stays silent: the host probe must time out.
        case "EXEC":
            let args = frame.arguments
            let numbers = args.split(separator: " ")
            if numbers.count == 2, let expected = Int(numbers[0]), Int(numbers[1]) != nil {
                withLock { assemblies[frame.token] = (expected, [:]) }
                debug("EXEC header token=\(frame.token) bytes=\(expected) chunks=\(numbers[1])")
            } else if let payload = Data(base64Encoded: args) {
                debug("EXEC inline token=\(frame.token) payload=\(payload.count)")
                await runCommand(token: frame.token, payload: payload)
            } else {
                emit(Wire.end(token: frame.token, exit: 125))
            }
        case "CHUNK":
            let parts = frame.arguments.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let index = Int(parts[0]),
                  let decoded = Data(base64Encoded: String(parts[1])) else {
                emit(Wire.end(token: frame.token, exit: 125))
                return
            }
            withLock {
                if var assembly = assemblies[frame.token] {
                    assembly.chunks[index] = decoded
                    assemblies[frame.token] = assembly
                } else {
                    missingChunkAssemblies.append(frame.token)
                }
            }
        case "RUN":
            let assembly = withLock { assemblies.removeValue(forKey: frame.token) }
            guard let assembly else {
                debug("RUN without assembly token=\(frame.token)")
                emit(Wire.end(token: frame.token, exit: 125))
                return
            }
            var payload = Data()
            for index in 0..<assembly.chunks.count {
                guard let chunk = assembly.chunks[index] else {
                    emit(Wire.end(token: frame.token, exit: 125))
                    return
                }
                payload.append(chunk)
            }
            await runCommand(token: frame.token, payload: payload)
        default:
            break
        }
    }

    private func currentCaps() -> String? {
        withLock {
            if runnerInstalled { return configuration.postRebootCaps }
            if configuration.runnerAlreadyCurrent { return configuration.initialCaps }
            return nil
        }
    }

    private func debug(_ message: String) {
        if ProcessInfo.processInfo.environment["FLOE_UPGRADE_DEBUG"] == "1" {
            FileHandle.standardError.write(Data("[harness] \(message)\n".utf8))
        }
    }

    private func emit(_ data: Data) {
        let target = withLock { continuation }
        let peek = String(decoding: data.prefix(48), as: UTF8.self).replacingOccurrences(of: "\u{1e}", with: "<RS>")
        debug("emit \(data.count) bytes router=\(target != nil) running=\(isRunning) head=\(peek)")
        target?.yield(data)
    }

    private func runCommand(token: String, payload: Data) async {
        // Payload fields are [cwd, stdin, argv0, argv1, ...].
        guard let fields = ScriptedGuestTransport.decodePayload(payload), fields.count >= 3 else {
            debug("payload decode failed (\(payload.count) bytes)")
            emit(Wire.marker("BEGIN", token) + Wire.end(token: token, exit: 126))
            return
        }
        let program = fields[2]
        if program == "/bin/echo" {
            // The host parser requires BEGIN before END on every token.
            var reply = Data()
            reply.append(Wire.marker("BEGIN", token))
            reply.append(Wire.marker("OUT", token))
            reply.append(Data((fields.dropFirst(3).joined(separator: " ") + "\n").utf8))
            reply.append(Wire.end(token: token, exit: 0))
            emit(reply)
            return
        }
        guard fields.count >= 5, program == "/bin/sh", fields[3] == "-c" else {
            debug("unexpected argv \(fields.map { $0.prefix(24) })")
            emit(Wire.marker("BEGIN", token) + Wire.end(token: token, exit: 126))
            return
        }
        let script = fields[4]
        let outcome = perform(script: script)
        var reply = Data()
        reply.append(Wire.marker("BEGIN", token))
        if !outcome.stdout.isEmpty {
            reply.append(Wire.marker("OUT", token))
            reply.append(Data(outcome.stdout.utf8))
        }
        if !outcome.stderr.isEmpty {
            reply.append(Wire.marker("ERR", token))
            reply.append(Data(outcome.stderr.utf8))
        }
        reply.append(Wire.end(token: token, exit: outcome.exit))
        emit(reply)
    }

    private struct Outcome {
        var exit: Int32
        var stdout: String = ""
        var stderr: String = ""
    }


    private func perform(script: String) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        if ProcessInfo.processInfo.environment["FLOE_UPGRADE_DEBUG"] == "1" {
            FileHandle.standardError.write(Data("[guest] script: \(script.prefix(160))\n".utf8))
        }
        // Install script: verify the staged bytes really match the digest the
        // host demands, and that the replacement keeps a recovery copy and
        // promotes atomically.
        if script.contains("sha512sum") {
            installScripts.append(script)
            guard let staged = guestFiles["/tmp/.floe-runner-upgrade/floe-exec.bin"] else {
                lastInstallError = "no staged runner"
                return Outcome(exit: 1, stderr: "no staged runner")
            }
            stagedRunnerBytes = staged
            guard let range = script.range(of: "[ \"$actual\" = \"") else {
                lastInstallError = "install script does not compare the digest"
                return Outcome(exit: 1, stderr: lastInstallError)
            }
            let digestStart = range.upperBound
            guard let digestEnd = script[digestStart...].firstIndex(of: "\"") else {
                lastInstallError = "install script digest is not terminated"
                return Outcome(exit: 1, stderr: lastInstallError)
            }
            let expected = String(script[digestStart..<digestEnd])
            let actual = FloeDigest.sha512Hex(staged)
            guard actual == expected else {
                lastInstallError = "sha512 mismatch (guest)"
                return Outcome(exit: 1, stderr: "sha512 mismatch")
            }
            guard script.contains(".prev"), script.contains("mv -f"), script.contains("/usr/local/bin/floe-exec") else {
                lastInstallError = "replacement is not atomic or keeps no recovery copy"
                return Outcome(exit: 1, stderr: lastInstallError)
            }
            if configuration.installRejects {
                lastInstallError = "simulated install failure"
                return Outcome(exit: 1, stderr: lastInstallError)
            }
            installedDigest = actual
            runnerInstalled = true
            guestFiles.removeAll()
            return Outcome(exit: 0, stdout: "floe-runner-installed\n")
        }
        if script.contains("base64 -d") {
            guard let sourceRange = script.range(of: "base64 -d ") else {
                return Outcome(exit: 1, stderr: "malformed decode")
            }
            let rest = script[sourceRange.upperBound...]
            guard let space = rest.firstIndex(of: " "), let arrow = script.range(of: " > ") else {
                return Outcome(exit: 1, stderr: "malformed decode")
            }
            let source = String(rest[..<space])
            let destination = String(script[arrow.upperBound...].prefix { $0 != " " })
            guard let encoded = guestFiles[source], !encoded.isEmpty,
                  let decoded = Data(base64Encoded: encoded) else {
                return Outcome(exit: 1, stderr: "cannot decode \(source)")
            }
            guestFiles[destination] = decoded
            guestFiles[source] = nil
            return Outcome(exit: 0)
        }
        if script.contains("printf '%s' '"), let appendRange = script.range(of: "' >> ") {
            let prefix = "printf '%s' '"
            guard let chunkStart = script.range(of: prefix)?.upperBound,
                  chunkStart <= appendRange.lowerBound else {
                return Outcome(exit: 1, stderr: "malformed chunk")
            }
            let chunk = String(script[chunkStart..<appendRange.lowerBound])
            let path = String(script[appendRange.upperBound...].prefix { $0 != " " && $0 != "\n" })
            var existing = guestFiles[path] ?? Data()
            existing.append(Data(chunk.utf8))
            guestFiles[path] = existing
            chunkCommands += 1
            return Outcome(exit: 0)
        }
        if script.hasPrefix("cp ") {
            // cp <guest path> <staged binary> && chmod 0600 <staged binary>
            shareCopyAttempts += 1
            if configuration.shareCopyFails {
                return Outcome(exit: 1, stderr: "simulated share copy failure")
            }
            let parts = script.split(separator: " ")
            guard parts.count >= 3 else { return Outcome(exit: 1, stderr: "malformed copy") }
            let guestPath = String(parts[1])
            let destination = String(parts[2].prefix { $0 != "&" })
            guard let hostDirectory = shareRoots["/floe/env"], guestPath.hasPrefix("/floe/env/") else {
                return Outcome(exit: 1, stderr: "share is not mounted")
            }
            let relative = String(guestPath.dropFirst("/floe/env/".count))
            let hostFile = URL(fileURLWithPath: hostDirectory).appendingPathComponent(relative)
            guard let data = try? Data(contentsOf: hostFile) else {
                return Outcome(exit: 1, stderr: "cannot read \(guestPath)")
            }
            guestFiles[destination] = data
            return Outcome(exit: 0)
        }
        if script.contains(": > ") {
            if let range = script.range(of: ": > ") {
                let path = String(script[range.upperBound...].prefix { $0 != " " && $0 != "\n" && $0 != "&" })
                guestFiles[path] = Data()
            }
            return Outcome(exit: 0)
        }
        if script.contains("mkdir -m 0700") {
            guestFiles.removeAll()
            return Outcome(exit: 0)
        }
        return Outcome(exit: 0)
    }

    static func decodePayload(_ payload: Data) -> [String]? {
        var index = payload.startIndex
        func readUInt32() -> UInt32? {
            guard payload.distance(from: index, to: payload.endIndex) >= 4 else { return nil }
            // Byte-wise big-endian read: the production payload writer appends
            // u32s big-endian (matching the guest runner's field_table parser),
            // and Data's withUnsafeBytes on a slice exposes the parent buffer,
            // so a direct byte loop is the only correct reader here.
            var value: UInt32 = 0
            for _ in 0..<4 {
                value = (value << 8) | UInt32(payload[index])
                index = payload.index(after: index)
            }
            return value
        }
        guard let count = readUInt32(), count > 0, count < 4096 else { return nil }
        var fields: [String] = []
        for _ in 0..<count {
            guard let length = readUInt32() else { return nil }
            let size = Int(length)
            guard payload.distance(from: index, to: payload.endIndex) >= size else { return nil }
            let bytes = payload[index..<payload.index(index, offsetBy: size)]
            fields.append(String(decoding: bytes, as: UTF8.self))
            index = payload.index(index, offsetBy: size)
        }
        return fields
    }
}

enum Wire {
    static func marker(_ name: String, _ token: String) -> Data {
        Data("\u{1e}FLOE-\(name) \(token)\u{1e}".utf8)
    }

    static func end(token: String, exit: Int32) -> Data {
        Data("\u{1e}FLOE-END \(token) \(exit)\u{1e}".utf8)
    }

    static func caps(token: String, capabilities: String) -> Data {
        var data = Data("\u{1e}FLOE-CAPS \(token) \(capabilities)\u{1e}".utf8)
        data.append(end(token: token, exit: 0))
        return data
    }
}

// MARK: - harness seams

final class HarnessEnvironments: LinuxGuestEnvironmentProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: [String: LinuxGuestEnvironmentDescriptor] = [:]

    func set(_ descriptor: LinuxGuestEnvironmentDescriptor) {
        lock.lock()
        descriptors[descriptor.id] = descriptor
        lock.unlock()
    }

    func linuxGuestEnvironment(id: String) async -> LinuxGuestEnvironmentDescriptor? {
        locked { descriptors[id] }
    }

    // Synchronous lock scope for async callers under Swift 6.
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

struct HarnessResolver: LinuxGuestImageResolving {
    var root: URL
    var images: [String: LinuxGuestImage]
    var failures: [String: String] = [:]

    var imageRoot: URL? { root }

    func linuxGuestImage(id: String) async -> LinuxGuestImage? { images[id] }

    func linuxGuestImageVerificationFailure(id: String) async -> String? { failures[id] }
}

/// One scripted VM per environment (a real device gives each guest its own
/// console stream; sharing one transport would make two routers compete for
/// the same bytes, which is exactly what production must never do).
final class HarnessVMHost: @unchecked Sendable {
    let configuration: ScriptedGuestTransport.Configuration
    let withShares: Bool
    let layers: [String: URL]
    private let lock = NSLock()
    private var transports: [String: ScriptedGuestTransport] = [:]

    init(
        configuration: ScriptedGuestTransport.Configuration,
        withShares: Bool,
        layers: [String: URL]
    ) {
        self.configuration = configuration
        self.withShares = withShares
        self.layers = layers
    }

    func transport(for environmentID: String) -> ScriptedGuestTransport {
        lock.lock()
        defer { lock.unlock() }
        if let existing = transports[environmentID] { return existing }
        let created = ScriptedGuestTransport(configuration: configuration)
        if ProcessInfo.processInfo.environment["FLOE_UPGRADE_DEBUG"] == "1" {
            FileHandle.standardError.write(Data(
                "[harness] new VM for \(environmentID) alreadyCurrent=\(configuration.runnerAlreadyCurrent) initialCaps=\(configuration.initialCaps ?? "nil")\n".utf8
            ))
        }
        if withShares, let layer = layers[environmentID] {
            created.setShareRoots(guestToHost: [LinuxGuestMountPoint.environment: layer.path])
        }
        transports[environmentID] = created
        return created
    }
}

struct HarnessSessionFactory: LinuxGuestSessionCreating {
    var host: HarnessVMHost

    func makeSession(
        descriptor: LinuxGuestEnvironmentDescriptor,
        image: LinuxGuestImage,
        limits: LinuxGuestLimits
    ) throws -> LinuxGuestSessionHandle {
        let transport = host.transport(for: descriptor.id)
        return LinuxGuestSessionHandle(
            transport: transport,
            start: { try await transport.machineStart() },
            stop: { await transport.machineStop() },
            close: { await transport.machineClose() },
            isRunning: { transport.isRunning },
            addForward: { _ in },
            removeForward: { _ in }
        )
    }
}

// MARK: - fixtures

enum Fixture {
    static let caps = "runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4"
    static let legacyCaps = "runner=1.0.0 protocol=2"

    static func directory(_ url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Writes the files an image manifest declares and returns its directory.
    @discardableResult
    static func imageDirectory(
        root: URL,
        id: String,
        disk: Data,
        runner: Data?,
        runnerIsSymlink: Bool = false
    ) throws -> URL {
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try Fixture.directory(root)
        try Fixture.directory(directory)
        try Data("bios-bytes".utf8).write(to: directory.appendingPathComponent("bios.bin"))
        try Data("kernel-bytes".utf8).write(to: directory.appendingPathComponent("kernel.bin"))
        try Data("initrd-bytes".utf8).write(to: directory.appendingPathComponent("initrd.bin"))
        try disk.write(to: directory.appendingPathComponent("disk.img"))
        if let runner {
            let runnerURL = directory.appendingPathComponent("floe-exec-riscv64")
            try runner.write(to: runnerURL)
            if runnerIsSymlink {
                let link = directory.appendingPathComponent("floe-exec-link")
                try? FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: runnerURL.path)
            }
        }
        return directory
    }

    static func artifact(role: LinuxGuestImageArtifact.Role, path: String, data: Data) -> LinuxGuestImageArtifact {
        LinuxGuestImageArtifact(role: role, path: path, sha512: FloeDigest.sha512Hex(data), bytes: Int64(data.count))
    }

    static func artifact(role: LinuxGuestImageArtifact.Role, path: String, file: URL) -> LinuxGuestImageArtifact {
        let data = (try? Data(contentsOf: file)) ?? Data()
        return artifact(role: role, path: path, data: data)
    }

    static func image(
        id: String,
        directory: URL,
        disk: Data,
        runner: Data?,
        runnerRole: LinuxGuestImageArtifact.Role = .runner,
        runnerPath: String = "floe-exec-riscv64",
        capabilities: String? = Fixture.caps,
        compatibleOrigins: [LinuxGuestCompatibleDiskOrigin]? = nil
    ) -> LinuxGuestImage {
        let bios = artifact(role: .bios, path: "bios.bin", file: directory.appendingPathComponent("bios.bin"))
        let kernel = artifact(role: .kernel, path: "kernel.bin", file: directory.appendingPathComponent("kernel.bin"))
        let initrd = artifact(role: .initrd, path: "initrd.bin", file: directory.appendingPathComponent("initrd.bin"))
        let diskArtifact = artifact(role: .disk, path: "disk.img", data: disk)
        var runnerArtifact: LinuxGuestImageArtifact?
        if let runner {
            if runnerPath == "floe-exec-link" {
                let link = directory.appendingPathComponent("floe-exec-link")
                runnerArtifact = LinuxGuestImageArtifact(
                    role: runnerRole,
                    path: runnerPath,
                    sha512: FloeDigest.sha512Hex(runner),
                    bytes: Int64(runner.count)
                )
                _ = link
            } else {
                runnerArtifact = LinuxGuestImageArtifact(
                    role: runnerRole,
                    path: runnerPath,
                    sha512: FloeDigest.sha512Hex(runner),
                    bytes: Int64(runner.count)
                )
            }
        }
        return LinuxGuestImage(
            id: id,
            biosPath: "bios.bin",
            kernelPath: "kernel.bin",
            initrdPath: "initrd.bin",
            diskPath: "disk.img",
            diskReadWrite: true,
            qualified: true,
            qualificationRun: "runner-upgrade-check",
            artifacts: [bios, kernel, initrd, diskArtifact],
            runnerArtifact: runnerArtifact,
            runnerCapabilities: runnerArtifact == nil ? nil : capabilities,
            compatibleOrigins: compatibleOrigins
        )
    }

    /// Environment writable layer with an existing disk cloned from `origin`.
    @discardableResult
    static func environmentLayer(
        root: URL,
        environmentID: String,
        disk: Data,
        originImageID: String,
        originDiskSHA512: String,
        originDiskBytes: Int64
    ) throws -> URL {
        let layer = root.appendingPathComponent("env-\(environmentID)", isDirectory: true)
        let diskDirectory = layer
            .appendingPathComponent("LinuxGuest", isDirectory: true)
            .appendingPathComponent("disks", isDirectory: true)
            .appendingPathComponent(environmentID, isDirectory: true)
        try directory(layer)
        try directory(diskDirectory)
        try disk.write(to: diskDirectory.appendingPathComponent("disk.img"))
        let origin = """
        {
          "artifactBytes" : \(originDiskBytes),
          "artifactSHA512" : "\(originDiskSHA512)",
          "createdAt" : "2026-09-20T00:00:00Z",
          "imageID" : "\(originImageID)",
          "version" : 1
        }
        """
        try Data(origin.utf8).write(to: diskDirectory.appendingPathComponent("origin.json"))
        return layer
    }

    static func descriptor(
        id: String,
        layer: URL,
        imageID: String,
        withShares: Bool,
        ramMB: Int? = nil
    ) -> LinuxGuestEnvironmentDescriptor {
        var shares: [LinuxGuestShare] = []
        if withShares {
            shares = [
                LinuxGuestShare(tag: LinuxGuestShare.environmentTag, hostDirectory: layer),
                LinuxGuestShare(tag: LinuxGuestShare.workspaceTag, hostDirectory: layer.appendingPathComponent("workspace", isDirectory: true))
            ]
        }
        return LinuxGuestEnvironmentDescriptor(
            id: id,
            writableDirectory: layer,
            shares: shares,
            imageID: imageID,
            ramMB: ramMB
        )
    }

    static func diskBytes(_ marker: String, size: Int = 4096) -> Data {
        var data = Data()
        let seed = Data((marker + "-mutable-guest-state").utf8)
        while data.count < size { data.append(seed) }
        return data
    }

    static func sha512(ofFile url: URL) -> String {
        (try? FloeDigest.sha512Hex(ofFileAt: url)) ?? "-"
    }
}

// MARK: - checks

@main
enum RunnerUpgradeCheck {
    static func main() async {
        let recorder = Recorder()

        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + 600, repeating: .never)
        watchdog.setEventHandler {
            FileHandle.standardError.write(Data("runner-upgrade-check watchdog: 600s elapsed; exiting\n".utf8))
            exit(3)
        }
        watchdog.resume()

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("floe-runner-upgrade-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try Fixture.directory(root)
        } catch {
            print("cannot create check scratch \(root.path): \(error)")
            exit(2)
        }

        await checkCompatibleOriginAdoption(recorder: recorder, root: root)
        await checkRunnerArtifactContract(recorder: recorder, root: root)
        await checkUpgradeWithShareStaging(recorder: recorder, root: root)
        await checkUpgradeWithConsoleUpload(recorder: recorder, root: root)
        await checkNoUpgradeWhenRunnerIsCurrent(recorder: recorder, root: root)
        await checkMissingRunnerArtifactRejects(recorder: recorder, root: root)
        await checkUnverifiedRunnerBytesReject(recorder: recorder, root: root)
        await checkAdmissionBounds(recorder: recorder, root: root)
        await checkRefusedStopQuarantines(recorder: recorder, root: root)

        print("")
        print("checks passed: \(recorder.passes), failures: \(recorder.failures.count)")
        for failure in recorder.failures {
            print("FAILURE: \(failure)")
        }
        if !recorder.failures.isEmpty { exit(1) }
    }

    // MARK: 1. manifest-level origin adoption

    static func checkCompatibleOriginAdoption(recorder: Recorder, root: URL) async {
        await recorder.check("compatible_predecessor_origin_is_adopted_untouched") {
            let scratch = root.appendingPathComponent("origin-adoption")
            let imageRoot = scratch.appendingPathComponent("images")
            let oldDiskSHA = String(repeating: "a", count: 128)
            let oldDiskBytes: Int64 = 4_000_000
            let oldImageID = "floe-debian13-riscv64-202609202607"
            let layer = try Fixture.environmentLayer(
                root: scratch,
                environmentID: "env-adopt",
                disk: Fixture.diskBytes("adopt"),
                originImageID: oldImageID,
                originDiskSHA512: oldDiskSHA,
                originDiskBytes: oldDiskBytes
            )
            let newDisk = Fixture.diskBytes("new-base")
            let imageDirectory = try Fixture.imageDirectory(
                root: imageRoot, id: "floe-debian13-riscv64-20260921",
                disk: newDisk, runner: Data("new-runner-bytes".utf8)
            )
            let image = Fixture.image(
                id: "floe-debian13-riscv64-20260921",
                directory: imageDirectory,
                disk: newDisk,
                runner: Data("new-runner-bytes".utf8),
                compatibleOrigins: [LinuxGuestCompatibleDiskOrigin(
                    imageID: oldImageID, artifactSHA512: oldDiskSHA, artifactBytes: oldDiskBytes
                )]
            )
            let diskURL = layer
                .appendingPathComponent("LinuxGuest/disks/env-adopt/disk.img")
            let originURL = layer
                .appendingPathComponent("LinuxGuest/disks/env-adopt/origin.json")
            let diskBefore = Fixture.sha512(ofFile: diskURL)
            let originBefore = try Data(contentsOf: originURL)
            let inodeBefore = (try? FileManager.default.attributesOfItem(atPath: diskURL.path)[.systemFileNumber]) as? NSNumber

            let runtime = try LinuxGuestRuntimeImagePreparer().prepare(
                image: image,
                imageDirectory: imageDirectory,
                environmentID: "env-adopt",
                writableDirectory: layer
            )
            try Recorder.expect(runtime.diskPath == diskURL.path,
                                "prepared disk path \(runtime.diskPath ?? "-") is not the existing environment disk")
            try Recorder.expect(Fixture.sha512(ofFile: diskURL) == diskBefore,
                                "the mutable environment disk was modified")
            let inodeAfter = (try? FileManager.default.attributesOfItem(atPath: diskURL.path)[.systemFileNumber]) as? NSNumber
            try Recorder.expect(inodeBefore == inodeAfter, "the environment disk file was replaced instead of reused")
            try Recorder.expect((try Data(contentsOf: originURL)) == originBefore,
                                "the original origin.json was rewritten")
            try Recorder.expect(runtime.biosPath == imageDirectory.appendingPathComponent("bios.bin").resolvingSymlinksInPath().path,
                                "bios did not resolve into the verified image directory")
        }

        await recorder.check("unrelated_origin_is_still_a_conflict_and_untouched") {
            let scratch = root.appendingPathComponent("origin-conflict")
            let imageRoot = scratch.appendingPathComponent("images")
            let strangerSHA = String(repeating: "b", count: 128)
            let oldDiskSHA = String(repeating: "c", count: 128)
            let layer = try Fixture.environmentLayer(
                root: scratch,
                environmentID: "env-conflict",
                disk: Fixture.diskBytes("conflict"),
                originImageID: "floe-debian13-riscv64-202609202607",
                originDiskSHA512: oldDiskSHA,
                originDiskBytes: 4_000_000
            )
            let newDisk = Fixture.diskBytes("new-base-conflict")
            let imageDirectory = try Fixture.imageDirectory(
                root: imageRoot, id: "floe-debian13-riscv64-20260921b",
                disk: newDisk, runner: Data("runner".utf8)
            )
            let image = Fixture.image(
                id: "floe-debian13-riscv64-20260921b",
                directory: imageDirectory,
                disk: newDisk,
                runner: Data("runner".utf8),
                compatibleOrigins: [LinuxGuestCompatibleDiskOrigin(
                    imageID: "floe-debian13-riscv64-202609202607",
                    artifactSHA512: strangerSHA,
                    artifactBytes: 4_000_000
                )]
            )
            let diskURL = layer.appendingPathComponent("LinuxGuest/disks/env-conflict/disk.img")
            let before = Fixture.sha512(ofFile: diskURL)
            do {
                _ = try LinuxGuestRuntimeImagePreparer().prepare(
                    image: image,
                    imageDirectory: imageDirectory,
                    environmentID: "env-conflict",
                    writableDirectory: layer
                )
                throw CheckFailure.message("an unrelated origin was adopted")
            } catch let error as LinuxGuestRuntimeImageError {
                guard case .diskOriginConflict = error else {
                    throw CheckFailure.message("unexpected error \(error)")
                }
            }
            try Recorder.expect(Fixture.sha512(ofFile: diskURL) == before, "the conflicting disk was modified")
        }
    }

    // MARK: 2. runner artifact contract and verifier

    static func checkRunnerArtifactContract(recorder: Recorder, root: URL) async {
        await recorder.check("runner_artifact_is_declared_and_verified_with_a_distinct_role") {
            let scratch = root.appendingPathComponent("artifact-contract")
            let imageRoot = scratch.appendingPathComponent("images")
            let disk = Fixture.diskBytes("contract")
            let runner = Data("runner-artifact-bytes".utf8)
            let directory = try Fixture.imageDirectory(
                root: imageRoot, id: "contract-image", disk: disk, runner: runner
            )
            let image = Fixture.image(
                id: "contract-image", directory: directory, disk: disk, runner: runner
            )
            try Recorder.expect(image.artifactDigest(role: .runner)?.path == "floe-exec-riscv64",
                                "the runner digest does not resolve")
            let declared = image.declaredArtifacts
            try Recorder.expect(declared.contains { $0.role == .runner && $0.path == "floe-exec-riscv64" },
                                "the runner is not a declared artifact")
            try Recorder.expect(image.qualificationFailure(imageDirectory: directory) == nil,
                                "a valid manifest with a runner artifact failed qualification")

            let verifier = LinuxGuestImageVerifier()
            try Recorder.expect(await verifier.verificationFailure(image: image, imageDirectory: directory) == nil,
                                "the verifier rejected a valid runner artifact")

            // A runner that declares the disk role is a contract violation.
            let wrongRoleDirectory = try Fixture.imageDirectory(
                root: imageRoot, id: "wrong-role", disk: disk, runner: runner
            )
            let wrongRole = Fixture.image(
                id: "wrong-role", directory: wrongRoleDirectory, disk: disk, runner: runner, runnerRole: .disk
            )
            let roleFailure = wrongRole.qualificationFailure(imageDirectory: wrongRoleDirectory) ?? ""
            try Recorder.expect(roleFailure.contains("runner"),
                                "a disk-role runner artifact was accepted: \(roleFailure)")

            // Missing capabilities payload.
            let noCaps = Fixture.image(
                id: "contract-image", directory: directory, disk: disk, runner: runner, capabilities: ""
            )
            let capsFailure = noCaps.qualificationFailure(imageDirectory: directory) ?? ""
            try Recorder.expect(capsFailure.contains("runnerCapabilities"),
                                "a runner artifact without capabilities was accepted: \(capsFailure)")

            // Old protocol capabilities.
            let oldProtocol = Fixture.image(
                id: "contract-image", directory: directory, disk: disk, runner: runner, capabilities: Fixture.legacyCaps
            )
            let protocolFailure = oldProtocol.qualificationFailure(imageDirectory: directory) ?? ""
            try Recorder.expect(protocolFailure.contains("protocol"),
                                "a protocol-2 runner artifact was accepted: \(protocolFailure)")

            // Structural checks: missing, wrong size, wrong digest, symlink,
            // escape.
            let missingRunnerDirectory = try Fixture.imageDirectory(
                root: imageRoot, id: "missing-runner", disk: disk, runner: runner
            )
            try FileManager.default.removeItem(at: missingRunnerDirectory.appendingPathComponent("floe-exec-riscv64"))
            let missingRunner = Fixture.image(id: "missing-runner", directory: missingRunnerDirectory, disk: disk, runner: runner)
            try Recorder.expect((missingRunner.qualificationFailure(imageDirectory: missingRunnerDirectory) ?? "").contains("missing"),
                                "a missing runner file was accepted")

            let wrongSize = LinuxGuestImageArtifact(
                role: .runner, path: "floe-exec-riscv64",
                sha512: FloeDigest.sha512Hex(runner), bytes: Int64(runner.count + 7)
            )
            var wrongSizeImage = image
            wrongSizeImage.runnerArtifact = wrongSize
            let wrongSizeFailure = await verifier.verificationFailure(image: wrongSizeImage, imageDirectory: directory) ?? ""
            try Recorder.expect(wrongSizeFailure.contains("size mismatch"),
                                "a wrong-size runner was accepted: \(wrongSizeFailure)")

            var wrongDigestImage = image
            wrongDigestImage.runnerArtifact = LinuxGuestImageArtifact(
                role: .runner, path: "floe-exec-riscv64",
                sha512: String(repeating: "d", count: 128), bytes: Int64(runner.count)
            )
            let wrongDigestFailure = await verifier.verificationFailure(image: wrongDigestImage, imageDirectory: directory) ?? ""
            try Recorder.expect(wrongDigestFailure.contains("SHA-512"),
                                "a wrong-digest runner was accepted: \(wrongDigestFailure)")

            // A symlinked runner path is never verified bytes.
            let symlinkDirectory = try Fixture.imageDirectory(
                root: imageRoot, id: "symlink-runner", disk: disk, runner: runner
            )
            let linkURL = symlinkDirectory.appendingPathComponent("floe-exec-link")
            try FileManager.default.createSymbolicLink(
                atPath: linkURL.path,
                withDestinationPath: symlinkDirectory.appendingPathComponent("floe-exec-riscv64").path
            )
            let symlinkImage = Fixture.image(
                id: "symlink-runner", directory: symlinkDirectory, disk: disk, runner: runner, runnerPath: "floe-exec-link"
            )
            let symlinkFailure = await verifier.verificationFailure(image: symlinkImage, imageDirectory: symlinkDirectory) ?? ""
            try Recorder.expect(symlinkFailure.contains("symlink") || symlinkFailure.contains("not a regular file"),
                                "a symlinked runner path was accepted: \(symlinkFailure)")

            var escapeImage = image
            escapeImage.runnerArtifact = LinuxGuestImageArtifact(
                role: .runner, path: "../outside-runner",
                sha512: FloeDigest.sha512Hex(runner), bytes: Int64(runner.count)
            )
            let escapeFailure = await verifier.verificationFailure(image: escapeImage, imageDirectory: directory) ?? ""
            try Recorder.expect(escapeFailure.contains("escapes"),
                                "an escaping runner path was accepted: \(escapeFailure)")

            // The verifier cache fingerprint changes with the runner bytes.
            let before = LinuxGuestImageVerifier.fingerprint(image: image, imageDirectory: directory)
            let replacement = Data("different-runner-bytes".utf8)
            var replacedImage = image
            replacedImage.runnerArtifact = LinuxGuestImageArtifact(
                role: .runner, path: "floe-exec-riscv64",
                sha512: FloeDigest.sha512Hex(replacement), bytes: Int64(replacement.count)
            )
            let after = LinuxGuestImageVerifier.fingerprint(image: replacedImage, imageDirectory: directory)
            try Recorder.expect(before != after, "the verifier cache fingerprint ignores the runner artifact")
        }

        await recorder.check("older_manifest_without_new_keys_still_decodes") {
            let json = """
            {
              "id": "old-image",
              "biosPath": "bios.bin",
              "diskPath": "disk.img",
              "diskReadWrite": true,
              "qualified": true,
              "qualificationRun": "old-run",
              "artifacts": [
                {"role": "bios", "path": "bios.bin", "sha512": "\(String(repeating: "0", count: 128))", "bytes": 1},
                {"role": "disk", "path": "disk.img", "sha512": "\(String(repeating: "1", count: 128))", "bytes": 1}
              ]
            }
            """
            let decoded = try JSONDecoder().decode(LinuxGuestImage.self, from: Data(json.utf8))
            try Recorder.expect(decoded.runnerArtifact == nil, "an old manifest gained a runner artifact")
            try Recorder.expect(decoded.compatibleOrigins == nil, "an old manifest gained compatible origins")
            try Recorder.expect(decoded.artifacts?.count == 2, "an old manifest lost artifacts")
        }
    }

    // MARK: 3. in-place upgrade with the 9p share staging path

    static func checkUpgradeWithShareStaging(recorder: Recorder, root: URL) async {
        await recorder.check("upgrade_stages_over_the_real_share_and_reboots_into_the_new_runner") {
            let harness = try makeHarness(
                root: root,
                name: "share-staging",
                configuration: .init(initialCaps: nil, postRebootCaps: Fixture.caps),
                withShares: true
            )
            let result = try await withDeadline(60, "share-staging start") {
                try await harness.registry.start(environmentID: "env-1", taskID: "task-1")
            }
            try Recorder.expect(result, "the registry did not own env-1")

            try Recorder.expect(harness.transport.startCount == 2,
                                "expected one boot plus one reboot, saw \(harness.transport.startCount)")
            try Recorder.expect(harness.transport.stopCount == 1,
                                "expected one host-side stop for the reboot, saw \(harness.transport.stopCount)")
            try Recorder.expect(harness.transport.closeCount == 0, "the transport was closed during a successful upgrade")
            try Recorder.expect(harness.transport.outputRequests == 1,
                                "the upgrade used more than one console reader: \(harness.transport.outputRequests) requests over generations \(harness.transport.readerGenerations)")
            try Recorder.expect(harness.transport.readerGenerations == [1],
                                "the console reader was replaced instead of surviving the reboot: \(harness.transport.readerGenerations)")
            try Recorder.expect(harness.transport.shareCopyAttempts == 1,
                                "the runner was not staged from the environment share")
            try Recorder.expect(harness.transport.chunkCommands == 0,
                                "the share staging path still uploaded base64 chunks")
            try Recorder.expect(harness.transport.stagedRunnerBytes == harness.runnerData,
                                "the guest did not receive the verified runner bytes")
            try Recorder.expect(harness.transport.installScripts.count == 1, "the install script did not run exactly once")
            try Recorder.expect(harness.transport.installScripts.first?.contains(harness.runnerDigest) == true,
                                "the install script does not verify the manifest digest in-guest")
            try Recorder.expect(!FileManager.default.fileExists(
                atPath: harness.layer.appendingPathComponent(".floe-runner-upgrade").path
            ), "the host share still carries the staging directory")
            try Recorder.expect(Fixture.sha512(ofFile: harness.diskURL) == harness.diskDigestBefore,
                                "the persistent disk changed on the host")
            try Recorder.expect(try Data(contentsOf: harness.originURL) == harness.originBefore,
                                "the original origin.json was rewritten")
            try Recorder.expect(harness.ledgerCaps() == Fixture.caps,
                                "the runner ledger does not record the verified CAPS payload")
            try Recorder.expect(await harness.registry.activeGuestCount == 1,
                                "the running session did not hold exactly one admission slot")
            try Recorder.expect(await harness.registry.reservedGuestRAMMB == 256,
                                "the session RAM reservation is wrong")

            let command = try await withDeadline(15, "post-upgrade command") {
                try await harness.registry.run(
                    environmentID: "env-1", argv: ["/bin/echo", "after-upgrade"],
                    workingDirectory: nil, standardInput: nil, timeout: 5, maxOutputBytes: 4096,
                    cancellation: nil
                )
            }
            try Recorder.expect(command.exitCode == 0, "a command after the upgrade failed: \(command.exitCode)")
            try Recorder.expect(command.stdout.contains("after-upgrade"), "no command output after the upgrade")

            await harness.registry.stop(environmentID: "env-1")
            try Recorder.expect(await harness.registry.activeGuestCount == 0, "the stop did not release the admission slot")
            // channel.close() and the machine handle both funnel into
            // transport.close(); what matters is that the VM/console is closed.
            try Recorder.expect(harness.transport.closeCount >= 1, "the stop did not close the transport")
            try Recorder.expect(!harness.transport.isRunning, "the transport still reports running after stop")
        }
    }

    // MARK: 4. console-upload fallback (no usable share)

    static func checkUpgradeWithConsoleUpload(recorder: Recorder, root: URL) async {
        await recorder.check("upgrade_falls_back_to_a_chunked_console_upload") {
            let harness = try makeHarness(
                root: root,
                name: "console-upload",
                configuration: .init(initialCaps: nil, postRebootCaps: Fixture.caps, shareCopyFails: true),
                withShares: true
            )
            _ = try await withDeadline(90, "console-upload start") {
                try await harness.registry.start(environmentID: "env-1", taskID: nil)
            }
            try Recorder.expect(harness.transport.shareCopyAttempts >= 1,
                                "the share path was not attempted first")
            try Recorder.expect(harness.transport.chunkCommands > 0,
                                "the console fallback uploaded no chunks")
            try Recorder.expect(harness.transport.stagedRunnerBytes == harness.runnerData,
                                "the console fallback did not reconstruct the verified runner bytes")
            try Recorder.expect(harness.ledgerCaps() == Fixture.caps, "the ledger was not written after the fallback upgrade")
            try Recorder.expect(Fixture.sha512(ofFile: harness.diskURL) == harness.diskDigestBefore,
                                "the persistent disk changed on the fallback path")
            await harness.registry.stop(environmentID: "env-1")
        }

        await recorder.check("upgrade_without_any_share_uses_the_console_upload") {
            let harness = try makeHarness(
                root: root,
                name: "no-share",
                configuration: .init(initialCaps: nil, postRebootCaps: Fixture.caps),
                withShares: false
            )
            _ = try await withDeadline(90, "no-share start") {
                try await harness.registry.start(environmentID: "env-1", taskID: nil)
            }
            try Recorder.expect(harness.transport.shareCopyAttempts == 0, "a share copy ran without a share")
            try Recorder.expect(harness.transport.chunkCommands > 0, "the console upload uploaded no chunks")
            try Recorder.expect(harness.transport.stagedRunnerBytes == harness.runnerData, "wrong bytes reached the guest")
            await harness.registry.stop(environmentID: "env-1")
        }
    }

    // MARK: 5. live probe, no ledger trust

    static func checkNoUpgradeWhenRunnerIsCurrent(recorder: Recorder, root: URL) async {
        await recorder.check("current_runner_is_probed_live_and_no_upgrade_runs") {
            let harness = try makeHarness(
                root: root,
                name: "current-runner",
                configuration: .init(initialCaps: Fixture.caps, postRebootCaps: Fixture.caps, runnerAlreadyCurrent: true),
                withShares: true,
            )
            // Even a matching ledger entry must not skip the live probe.
            try LinuxGuestRuntimeImagePreparer.recordRunnerCapabilities(
                Fixture.caps, writableDirectory: harness.layer, environmentID: "env-1"
            )
            _ = try await withDeadline(30, "current-runner start") {
                try await harness.registry.start(environmentID: "env-1", taskID: nil)
            }
            try Recorder.expect(harness.transport.startCount == 1, "a reboot happened without an upgrade")
            try Recorder.expect(harness.transport.stopCount == 0, "a stop happened without an upgrade")
            try Recorder.expect(harness.transport.installScripts.isEmpty, "an install ran for a current runner")
            try Recorder.expect(harness.transport.outputRequests == 1,
                                "the live probe did not use exactly one console reader")
            try Recorder.expect(harness.transport.readerGenerations == [1],
                                "a second console reader was opened for a current runner")
            try Recorder.expect(harness.ledgerCaps() == Fixture.caps, "the ledger was not kept truthful")
            _ = try await withDeadline(15, "current-runner command") {
                try await harness.registry.run(
                    environmentID: "env-1", argv: ["/bin/echo", "live"],
                    workingDirectory: nil, standardInput: nil, timeout: 5, maxOutputBytes: 4096,
                    cancellation: nil
                )
            }
            await harness.registry.stop(environmentID: "env-1")
        }

        await recorder.check("legacy_runner_is_detected_by_a_finite_live_probe_not_the_ledger") {
            let harness = try makeHarness(
                root: root,
                name: "ledger-not-trusted",
                configuration: .init(initialCaps: nil, postRebootCaps: Fixture.caps),
                withShares: true
            )
            // A stale ledger that claims the runner is current must not be
            // believed: the live probe is silent, so the upgrade must still
            // run and the disk must not be reset.
            try LinuxGuestRuntimeImagePreparer.recordRunnerCapabilities(
                Fixture.caps, writableDirectory: harness.layer, environmentID: "env-1"
            )
            _ = try await withDeadline(60, "ledger-not-trusted start") {
                try await harness.registry.start(environmentID: "env-1", taskID: nil)
            }
            try Recorder.expect(harness.transport.installScripts.count == 1,
                                "the stale ledger was trusted instead of probing the live runner")
            try Recorder.expect(Fixture.sha512(ofFile: harness.diskURL) == harness.diskDigestBefore,
                                "the persistent disk changed while the ledger was stale")
            await harness.registry.stop(environmentID: "env-1")
        }
    }

    // MARK: 6. rejection paths preserve the disk

    static func checkMissingRunnerArtifactRejects(recorder: Recorder, root: URL) async {
        await recorder.check("missing_runner_artifact_fails_closed_and_preserves_the_disk") {
            let scratch = root.appendingPathComponent("missing-artifact")
            let imageRoot = scratch.appendingPathComponent("images")
            let disk = Fixture.diskBytes("missing-artifact")
            let layer = try Fixture.environmentLayer(
                root: scratch, environmentID: "env-1", disk: Fixture.diskBytes("env-missing"),
                originImageID: "old-image", originDiskSHA512: String(repeating: "e", count: 128), originDiskBytes: 4096
            )
            let imageDirectory = try Fixture.imageDirectory(
                root: imageRoot, id: "new-image", disk: disk, runner: nil
            )
            var image = Fixture.image(id: "new-image", directory: imageDirectory, disk: disk, runner: nil)
            image.compatibleOrigins = [LinuxGuestCompatibleDiskOrigin(
                imageID: "old-image", artifactSHA512: String(repeating: "e", count: 128), artifactBytes: 4096
            )]
            let host = HarnessVMHost(
                configuration: .init(initialCaps: nil, postRebootCaps: Fixture.caps),
                withShares: true,
                layers: ["env-1": layer]
            )
            let transport = host.transport(for: "env-1")
            let environments = HarnessEnvironments()
            environments.set(Fixture.descriptor(id: "env-1", layer: layer, imageID: "new-image", withShares: true))
            let registry = TinyEMULinuxGuestRegistry(
                environments: environments,
                images: HarnessResolver(root: imageRoot, images: ["new-image": image]),
                limits: LinuxGuestLimits(runnerProbeTimeout: 0.5),
                factory: HarnessSessionFactory(host: host)
            )
            let diskURL = layer.appendingPathComponent("LinuxGuest/disks/env-1/disk.img")
            let before = Fixture.sha512(ofFile: diskURL)
            do {
                _ = try await registry.start(environmentID: "env-1", taskID: nil)
                throw CheckFailure.message("a legacy runner without an upgrade artifact was allowed to start")
            } catch let error as LinuxGuestError {
                guard case .runnerUpgradeRequired = error else {
                    throw CheckFailure.message("unexpected error \(error)")
                }
            }
            try Recorder.expect(Fixture.sha512(ofFile: diskURL) == before, "the disk changed on a rejected start")
            try Recorder.expect(transport.installScripts.isEmpty, "an install ran without a runner artifact")
            // The failed start closes the channel and the handle (both funnel
            // into the transport close); what matters is the VM is not left
            // running when it can be stopped.
            try Recorder.expect(transport.closeCount >= 1, "the failed start did not close its VM")
            try Recorder.expect(!transport.isRunning, "the failed start left its VM running")
            try Recorder.expect(await registry.activeGuestCount == 0, "the failed start leaked an admission slot")
        }
    }

    static func checkUnverifiedRunnerBytesReject(recorder: Recorder, root: URL) async {
        await recorder.check("wrong_digest_runner_bytes_are_rejected_before_any_replacement") {
            let harness = try makeHarness(
                root: root,
                name: "wrong-digest",
                configuration: .init(initialCaps: nil, postRebootCaps: Fixture.caps),
                withShares: true,
                
                corruptRunnerDigest: true
            )
            do {
                _ = try await withDeadline(30, "wrong-digest start") {
                    try await harness.registry.start(environmentID: "env-1", taskID: nil)
                }
                throw CheckFailure.message("a wrong-digest runner artifact was used")
            } catch is CheckFailure {
                throw CheckFailure.message("a wrong-digest runner artifact was used")
            } catch {
                // Expected: the artifact never passes the shared digest check.
            }
            try Recorder.expect(harness.transport.installScripts.isEmpty, "the guest received unverified bytes")
            try Recorder.expect(Fixture.sha512(ofFile: harness.diskURL) == harness.diskDigestBefore, "the disk changed")
            try Recorder.expect(await harness.registry.activeGuestCount == 0, "the rejected start leaked an admission slot")
        }

        await recorder.check("symlinked_runner_artifact_is_rejected") {
            let harness = try makeHarness(
                root: root,
                name: "symlink-runner",
                configuration: .init(initialCaps: nil, postRebootCaps: Fixture.caps),
                withShares: true,
                
                runnerPath: "floe-exec-link"
            )
            do {
                _ = try await withDeadline(30, "symlink start") {
                    try await harness.registry.start(environmentID: "env-1", taskID: nil)
                }
                throw CheckFailure.message("a symlinked runner artifact was used")
            } catch is CheckFailure {
                throw CheckFailure.message("a symlinked runner artifact was used")
            } catch {
                // Expected: the shared path check refuses the symlink.
            }
            try Recorder.expect(harness.transport.installScripts.isEmpty, "the guest received bytes from a symlink")
            try Recorder.expect(Fixture.sha512(ofFile: harness.diskURL) == harness.diskDigestBefore, "the disk changed")
        }

        await recorder.check("install_failure_stops_without_resetting_the_disk") {
            let harness = try makeHarness(
                root: root,
                name: "install-failure",
                configuration: .init(initialCaps: nil, postRebootCaps: Fixture.caps, installRejects: true),
                withShares: true
            )
            do {
                _ = try await withDeadline(60, "install-failure start") {
                    try await harness.registry.start(environmentID: "env-1", taskID: nil)
                }
                throw CheckFailure.message("a failed in-guest install still reported a running guest")
            } catch is CheckFailure {
                throw CheckFailure.message("a failed in-guest install still reported a running guest")
            } catch {
                // Expected: the replacement failed inside the guest.
            }
            try Recorder.expect(harness.transport.installScripts.count == 1, "the install did not run")
            try Recorder.expect(harness.transport.stopCount == 0, "the guest was rebooted after a failed install")
            try Recorder.expect(Fixture.sha512(ofFile: harness.diskURL) == harness.diskDigestBefore, "the disk changed")
            try Recorder.expect(await harness.registry.activeGuestCount == 0, "the failed start leaked an admission slot")
        }
    }

    // MARK: 7. bounded admission

    static func checkAdmissionBounds(recorder: Recorder, root: URL) async {
        await recorder.check("duplicate_concurrent_start_is_refused_and_slots_release") {
            let harness = try makeHarness(
                root: root,
                name: "duplicate-start",
                configuration: .init(initialCaps: Fixture.caps, postRebootCaps: Fixture.caps,
                                     runnerAlreadyCurrent: true, bootDelayMilliseconds: 600),
                withShares: true,
                
                maxActiveGuests: 4,
                maxGuestRAMMB: 1024
            )
            let first = Task { try await harness.registry.start(environmentID: "env-1", taskID: nil) }
            // Wait until the start holds its admission slot (it is sleeping in
            // its boot): a second start must be refused as already starting.
            var waited = 0
            while await harness.registry.activeGuestCount == 0 && waited < 100 {
                try? await Task.sleep(for: .milliseconds(20))
                waited += 1
            }
            do {
                _ = try await harness.registry.start(environmentID: "env-1", taskID: nil)
                throw CheckFailure.message("a duplicate concurrent start created a second VM")
            } catch let error as LinuxGuestError {
                guard case .guestBusy = error else {
                    throw CheckFailure.message("unexpected duplicate-start error \(error)")
                }
            }
            let started = try await first.value
            try Recorder.expect(started, "the first start did not finish")
            try Recorder.expect(harness.transport.startCount == 1, "a duplicate VM was booted")
            await harness.registry.stop(environmentID: "env-1")
            try Recorder.expect(await harness.registry.activeGuestCount == 0, "the slot was not released")
        }

        await recorder.check("guest_count_and_ram_budget_refuse_a_new_start_without_killing_others") {
            var nameCounter = 0
            func harness(_ limit: Int, _ ram: Int) throws -> Harness {
                nameCounter += 1
                return try makeHarness(
                    root: root.appendingPathComponent("admission-\(nameCounter)"),
                    name: "admission-\(nameCounter)",
                    configuration: .init(initialCaps: Fixture.caps, postRebootCaps: Fixture.caps, runnerAlreadyCurrent: true),
                    withShares: true,
                    
                    environmentIDs: ["env-1", "env-2", "env-3"],
                    maxActiveGuests: limit,
                    maxGuestRAMMB: ram
                )
            }

            // Guest count limit.
            let countLimited = try harness(2, 1024)
            _ = try await countLimited.registry.start(environmentID: "env-1", taskID: nil)
            _ = try await countLimited.registry.start(environmentID: "env-2", taskID: nil)
            do {
                _ = try await countLimited.registry.start(environmentID: "env-3", taskID: nil)
                throw CheckFailure.message("the guest-count limit was not enforced")
            } catch let error as LinuxGuestError {
                guard case .capacityReached(let detail) = error else {
                    throw CheckFailure.message("unexpected capacity error \(error)")
                }
                try Recorder.expect(detail.contains("limit 2"), "the capacity error does not report the limit: \(detail)")
            }
            try Recorder.expect(await countLimited.registry.status(environmentID: "env-1").running,
                                "an active guest was stopped to make room")
            try Recorder.expect(await countLimited.registry.status(environmentID: "env-2").running,
                                "an active guest was stopped to make room")
            await countLimited.registry.stop(environmentID: "env-1")
            _ = try await countLimited.registry.start(environmentID: "env-3", taskID: nil)
            let status = await countLimited.registry.status(environmentID: "env-3")
            try Recorder.expect(status.activeGuestCount == 2, "capacity reporting is wrong: \(String(describing: status.activeGuestCount))")

            // RAM budget: 2 x 256 MB fit in 512 MB, the third is refused.
            let ramLimited = try harness(4, 512)
            _ = try await ramLimited.registry.start(environmentID: "env-1", taskID: nil)
            _ = try await ramLimited.registry.start(environmentID: "env-2", taskID: nil)
            do {
                _ = try await ramLimited.registry.start(environmentID: "env-3", taskID: nil)
                throw CheckFailure.message("the guest RAM budget was not enforced")
            } catch let error as LinuxGuestError {
                guard case .capacityReached(let detail) = error else {
                    throw CheckFailure.message("unexpected RAM capacity error \(error)")
                }
                try Recorder.expect(detail.contains("MB"), "the RAM capacity error does not report the budget: \(detail)")
            }
            try Recorder.expect(await ramLimited.registry.reservedGuestRAMMB == 512, "the RAM reservation is wrong")
            await ramLimited.registry.stopAll()
            try Recorder.expect(await ramLimited.registry.activeGuestCount == 0, "stopAll did not release every slot")
        }
    }

    // MARK: 8. truthful stop / quarantine

    static func checkRefusedStopQuarantines(recorder: Recorder, root: URL) async {
        await recorder.check("refused_stop_reports_still_running_and_quarantines_the_disk") {
            let harness = try makeHarness(
                root: root,
                name: "refused-stop",
                configuration: .init(initialCaps: Fixture.caps, postRebootCaps: Fixture.caps,
                                     runnerAlreadyCurrent: true, refusesStop: true),
                withShares: true
            )
            _ = try await withDeadline(30, "refused-stop start") {
                try await harness.registry.start(environmentID: "env-1", taskID: nil)
            }
            try Recorder.expect(harness.transport.startCount == 1, "the first start did not boot once")

            await harness.registry.stop(environmentID: "env-1")
            let status = await harness.registry.status(environmentID: "env-1")
            try Recorder.expect(status.running, "a refused stop reported the guest as stopped")
            try Recorder.expect((status.lastError ?? "").contains("still running"),
                                "no truthful stop error was recorded: \(status.lastError ?? "-")")
            try Recorder.expect((status.lastResetSharedImpact ?? "").contains("STILL RUNNING"),
                                "the stop impact does not report the quarantine: \(status.lastResetSharedImpact ?? "-")")
            try Recorder.expect(await harness.registry.activeGuestCount == 1,
                                "the quarantined guest released its admission slot")
            try Recorder.expect(harness.transport.startCount == 1, "the refused stop destroyed or replaced the VM")
            try Recorder.expect(Fixture.sha512(ofFile: harness.diskURL) == harness.diskDigestBefore,
                                "the persistent disk changed during the failed stop")

            // A new start must not boot a second VM on the same disk.
            do {
                _ = try await harness.registry.start(environmentID: "env-1", taskID: nil)
                throw CheckFailure.message("a start after a failed stop booted a second VM")
            } catch let error as LinuxGuestError {
                guard case .stopFailed = error else {
                    throw CheckFailure.message("unexpected error after a failed stop \(error)")
                }
            }
            try Recorder.expect(harness.transport.startCount == 1, "a second VM was booted on the quarantined disk")

            // A retry recovers: the second stop attempt really stops the VM.
            harness.transport.allowStop()
            await harness.registry.stop(environmentID: "env-1")
            try Recorder.expect(!harness.transport.isRunning, "the retry stop did not stop the VM")
            try Recorder.expect(await harness.registry.activeGuestCount == 0,
                                "the successful retry did not release the admission slot")
            let recovered = await harness.registry.status(environmentID: "env-1")
            try Recorder.expect(!recovered.running, "the recovered guest still reports running")
            try Recorder.expect((recovered.lastResetSharedImpact ?? "").contains("stopped and destroyed"),
                                "the recovered stop impact is not truthful: \(recovered.lastResetSharedImpact ?? "-")")
        }

        await recorder.check("failed_start_whose_vm_refuses_stop_is_quarantined_not_orphaned") {
            let harness = try makeHarness(
                root: root,
                name: "failed-start-refuses-stop",
                configuration: .init(initialCaps: nil, postRebootCaps: Fixture.caps,
                                     installRejects: true, refusesStop: true),
                withShares: true
            )
            // Legacy runner -> the in-guest install is rejected -> start fails
            // while the VM is alive and refuses to close.
            do {
                _ = try await withDeadline(60, "failed-start") {
                    try await harness.registry.start(environmentID: "env-1", taskID: nil)
                }
                throw CheckFailure.message("a failed install reported a running guest")
            } catch is CheckFailure {
                throw CheckFailure.message("a failed install reported a running guest")
            } catch {
                // Expected: install rejection fails the start.
            }
            try Recorder.expect(harness.transport.isRunning, "the scenario needs a VM that refused to stop")
            try Recorder.expect(harness.transport.installScripts.count == 1, "the install did not run")
            // Same stop contract as stopGuest: the surviving VM is retained
            // with its reservation instead of being orphaned.
            try Recorder.expect(await harness.registry.activeGuestCount == 1,
                                "the orphaned VM released its admission slot")
            let status = await harness.registry.status(environmentID: "env-1")
            try Recorder.expect(status.running, "a quarantined failed start reports not running")
            try Recorder.expect((status.lastError ?? "").contains("still running"),
                                "the failed start did not report the surviving VM: \(status.lastError ?? "-")")
            try Recorder.expect(Fixture.sha512(ofFile: harness.diskURL) == harness.diskDigestBefore,
                                "the persistent disk changed during the failed start")
            // A new start must not boot a second VM on the same disk.
            do {
                _ = try await harness.registry.start(environmentID: "env-1", taskID: nil)
                throw CheckFailure.message("a start after a failed start booted a second VM")
            } catch let error as LinuxGuestError {
                guard case .stopFailed = error else {
                    throw CheckFailure.message("unexpected error after a failed start \(error)")
                }
            }
            try Recorder.expect(harness.transport.startCount == 1, "a second VM was booted on the quarantined disk")
            // stopGuest recovers the retained handle.
            harness.transport.allowStop()
            await harness.registry.stop(environmentID: "env-1")
            try Recorder.expect(!harness.transport.isRunning, "the recovery stop did not stop the VM")
            try Recorder.expect(await harness.registry.activeGuestCount == 0,
                                "the recovery stop did not release the admission slot")
        }
    }

    // MARK: harness plumbing

    struct Harness: @unchecked Sendable {
        var registry: TinyEMULinuxGuestRegistry
        var host: HarnessVMHost
        var layer: URL
        var diskURL: URL
        var originURL: URL
        var runnerData: Data
        var runnerDigest: String
        var diskDigestBefore: String
        var originBefore: Data

        var transport: ScriptedGuestTransport { host.transport(for: "env-1") }

        func ledgerCaps() -> String? {
            LinuxGuestRuntimeImagePreparer.recordedRunnerCapabilities(
                writableDirectory: layer, environmentID: "env-1"
            )
        }
    }

    static func makeHarness(
        root: URL,
        name: String,
        configuration: ScriptedGuestTransport.Configuration,
        withShares: Bool,
        runnerPath: String = "floe-exec-riscv64",
        corruptRunnerDigest: Bool = false,
        environmentIDs: [String] = ["env-1"],
        maxActiveGuests: Int = 4,
        maxGuestRAMMB: Int = 1536
    ) throws -> Harness {
        let scratch = root.appendingPathComponent(name)
        let imageRoot = scratch.appendingPathComponent("images")
        try Fixture.directory(scratch)
        let runnerData = Data((0..<96_000).map { UInt8(($0 &* 37) & 0xff) })
        let newDisk = Fixture.diskBytes("new-base-\(name)")
        let imageID = "new-image-\(name)"
        let imageDirectory = try Fixture.imageDirectory(
            root: imageRoot, id: imageID, disk: newDisk, runner: runnerData
        )
        if runnerPath != "floe-exec-riscv64" {
            try Data("linked-runner".utf8).write(to: imageDirectory.appendingPathComponent("floe-exec-riscv64"))
        }
        var layers: [String: URL] = [:]
        for environmentID in environmentIDs {
            layers[environmentID] = try Fixture.environmentLayer(
                root: scratch,
                environmentID: environmentID,
                disk: Fixture.diskBytes("env-\(environmentID)-\(name)"),
                originImageID: "old-image",
                originDiskSHA512: String(repeating: "f", count: 128),
                originDiskBytes: 4096
            )
        }
        let layer = layers["env-1"]!
        var image = Fixture.image(
            id: imageID,
            directory: imageDirectory,
            disk: newDisk,
            runner: runnerData,
            runnerPath: runnerPath,
            compatibleOrigins: [LinuxGuestCompatibleDiskOrigin(
                imageID: "old-image",
                artifactSHA512: String(repeating: "f", count: 128),
                artifactBytes: 4096
            )]
        )
        if corruptRunnerDigest, var artifact = image.runnerArtifact {
            artifact.sha512 = String(repeating: "9", count: 128)
            image.runnerArtifact = artifact
        }
        let host = HarnessVMHost(configuration: configuration, withShares: withShares, layers: layers)
        let environments = HarnessEnvironments()
        for environmentID in environmentIDs {
            environments.set(Fixture.descriptor(
                id: environmentID, layer: layers[environmentID]!, imageID: imageID, withShares: withShares
            ))
        }
        let registry = TinyEMULinuxGuestRegistry(
            environments: environments,
            images: HarnessResolver(root: imageRoot, images: [imageID: image]),
            limits: LinuxGuestLimits(
                maxActiveGuests: maxActiveGuests,
                maxGuestRAMMB: maxGuestRAMMB,
                runnerProbeTimeout: 3.0
            ),
            factory: HarnessSessionFactory(host: host)
        )
        let diskURL = layer.appendingPathComponent("LinuxGuest/disks/env-1/disk.img")
        let originURL = layer.appendingPathComponent("LinuxGuest/disks/env-1/origin.json")
        return Harness(
            registry: registry,
            host: host,
            layer: layer,
            diskURL: diskURL,
            originURL: originURL,
            runnerData: runnerData,
            runnerDigest: FloeDigest.sha512Hex(runnerData),
            diskDigestBefore: Fixture.sha512(ofFile: diskURL),
            originBefore: try Data(contentsOf: originURL)
        )
    }
}
