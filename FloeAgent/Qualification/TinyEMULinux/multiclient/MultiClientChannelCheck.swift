// MultiClientChannelCheck — one shared guest console, several concurrent
// clients (parent task + full-power children), driven through the *production*
// `LinuxGuestCommandChannel` against the real `floe-exec` runner built for
// this host.
//
// The harness is the "local module barrier" for multi-client correctness:
// the same production actor that serves the app drives a real console here,
// and every client is identified by its own command token, its own process,
// its own cwd/stdout/stderr/exit code. The scenarios assert:
//
//   1. three clients run genuinely concurrently (mutual start-file barrier;
//      a serialized console fails with a distinct NO_OVERLAP marker);
//   2. identity, cwd, stdout, stderr, exit code and environment stay per
//      client — no cross-talk;
//   3. cancelling one client reaps only its own process group; the other
//      clients finish and the console stays usable;
//   4. an invalid destination fails that client honestly (exit 126/127) and
//      never poisons the console for the others;
//   5. closing the console while clients are active yields honest failures
//      for every active client, never a fake success, and never a hang;
//   6. concurrent unsynchronized same-path writers are recorded for what the
//      VM layer actually guarantees (whole process writes; coordination is
//      the runtime mutation lease's responsibility, not this layer's).
//
// Usage: multiclient-check <floe-exec path> <work dir> <json out path>

import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - failures

struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { self.description = text }
}

struct OperationTimeout: Error, CustomStringConvertible {
    let seconds: TimeInterval
    var description: String { "operation exceeded its \(seconds)s deadline" }
}

/// Runs `operation` under a hard deadline. The operation's task is cancelled
/// when the deadline fires; the harness never waits on a wedged client
/// forever.
func withDeadline<T: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw OperationTimeout(seconds: seconds)
        }
        guard let first = try await group.next() else {
            throw OperationTimeout(seconds: seconds)
        }
        group.cancelAll()
        return first
    }
}

// MARK: - real runner transport

/// One real `floe-exec` process seen as a byte console: stdin is the framed
/// channel the harness writes, stdout is the framed channel the runner emits,
/// stderr is runner diagnostics.
final class RunnerConsole: LinuxGuestConsoleTransport, @unchecked Sendable {
    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var stream: AsyncStream<Data>?
    private var continuation: AsyncStream<Data>.Continuation?
    private var stdinClosed = false
    private var stderrBox = Data()
    private var stderrThread: Thread?
    /// Cached descriptors: `FileHandle.fileDescriptor` raises an Objective-C
    /// exception once the handle was closed, which a Swift error path must
    /// never hit. The fds stay valid for the process lifetime; the write path
    /// reports a Swift error instead.
    private let writeFD: Int32
    private let readFD: Int32
    private var writtenBytes: [UInt8] = []

    /// Every byte the channel wrote to the console, for identity assertions.
    func writtenText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: writtenBytes, as: UTF8.self)
    }

    init(runnerPath: String) throws {
        process.executableURL = URL(fileURLWithPath: runnerPath)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        writeFD = input.fileHandleForWriting.fileDescriptor
        readFD = output.fileHandleForReading.fileDescriptor
        try process.run()
        let errorHandle = errors.fileHandleForReading
        let box = self
        let thread = Thread {
            while true {
                let chunk = errorHandle.availableData
                if chunk.isEmpty { break }
                box.appendDiagnostics(chunk)
            }
        }
        thread.stackSize = 1 << 20
        thread.start()
        stderrThread = thread
    }

    var diagnostics: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: stderrBox, as: UTF8.self)
    }

    private func appendDiagnostics(_ chunk: Data) {
        lock.lock()
        stderrBox.append(chunk)
        lock.unlock()
    }

    func output() async -> AsyncStream<Data> {
        if let existing = existingStream() { return existing }
        var captured: AsyncStream<Data>.Continuation!
        // Unbounded on purpose: this harness measures the channel's routing,
        // and the production transport's bounded console policy is a separate
        // concern (covered by the production runtime).
        let created = AsyncStream<Data>(bufferingPolicy: .unbounded) { captured = $0 }
        installStream(created, continuation: captured)
        let fd = readFD
        let emit = captured!
        let reader = Thread {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 200)
                if ready < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if ready == 0 { continue }
                let got = buffer.withUnsafeMutableBytes { raw -> Int in
                    read(fd, raw.baseAddress, raw.count)
                }
                if got < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    break
                }
                if got == 0 { break }
                emit.yield(Data(buffer[0..<got]))
            }
            emit.finish()
        }
        reader.stackSize = 1 << 20
        reader.start()
        return created
    }

    /// Synchronous helper: NSLock must not be taken directly in an async
    /// context (Swift 6).
    private func existingStream() -> AsyncStream<Data>? {
        lock.lock()
        defer { lock.unlock() }
        return stream
    }

    private func installStream(_ created: AsyncStream<Data>, continuation: AsyncStream<Data>.Continuation) {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return }
        stream = created
        self.continuation = continuation
    }

    func write(_ bytes: [UInt8]) async throws {
        guard !stdinIsClosed() else {
            throw HarnessError("console is closed")
        }
        recordWritten(bytes)
        let fd = writeFD
        try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let wrote = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if wrote < 0 {
                    if errno == EINTR { continue }
                    throw HarnessError("console write failed: \(String(cString: strerror(errno)))")
                }
                offset += wrote
            }
        }
    }

    /// Synchronous helper: NSLock must not be taken directly in an async
    /// context (Swift 6).
    private func stdinIsClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stdinClosed
    }

    private func recordWritten(_ bytes: [UInt8]) {
        lock.lock()
        writtenBytes.append(contentsOf: bytes)
        lock.unlock()
    }

    /// EOF on stdin is the runner's documented stop signal: it kills every
    /// active command/session group and exits. A real close then waits for
    /// the process, escalating to SIGKILL only if it does not leave.
    func close() async {
        let alreadyClosed = markStdinClosed()
        if !alreadyClosed {
            input.fileHandleForWriting.closeFile()
        }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// Hard kill without the graceful EOF, used by the harness teardown so a
    /// failed scenario cannot leak a runner process.
    func terminateNow() {
        let alreadyClosed = markStdinClosed()
        if !alreadyClosed {
            input.fileHandleForWriting.closeFile()
        }
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline {
                usleep(50_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    /// Synchronous helper: NSLock must not be taken directly in an async
    /// context (Swift 6).
    private func markStdinClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let alreadyClosed = stdinClosed
        stdinClosed = true
        return alreadyClosed
    }
}

// MARK: - one client result

/// Frame-token inspection over what the channel wrote to the real console.
enum TestTokens {
    static func execTokens(in console: RunnerConsole) -> [String] {
        tokens(in: console.writtenText(), name: "EXEC")
    }

    static func tokens(in text: String, name: String) -> [String] {
        let marker = "\u{1e}FLOE-\(name) "
        var result: [String] = []
        var search = text.startIndex
        while let range = text.range(of: marker, range: search..<text.endIndex) {
            let token = text[range.upperBound...].prefix { character in
                character != " " && character != "\u{1e}" && character != "\n" && character != "\r"
            }
            if !token.isEmpty { result.append(String(token)) }
            search = range.upperBound
        }
        return result
    }
}

struct ClientOutcome: Sendable {
    let token: String
    let startedAt: Date
    let finishedAt: Date
    let status: String        // "exited" | "cancelled" | "error"
    let exitCode: Int32?
    let stdout: String
    let stderr: String
    let errorText: String?

    var elapsed: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}

func runClient(
    _ channel: LinuxGuestCommandChannel,
    token: String,
    command: String,
    cwd: String,
    cancellation: CancellationToken? = nil,
    timeout: TimeInterval,
    maxOutputBytes: Int = 256 * 1024
) async -> ClientOutcome {
    let started = Date()
    do {
        let result = try await withDeadline(seconds: timeout) {
            try await channel.run(
                argv: ["/bin/sh", "-c", command],
                workingDirectory: cwd,
                standardInput: nil,
                timeout: timeout - 1,
                maxOutputBytes: maxOutputBytes,
                cancellation: cancellation
            )
        }
        return ClientOutcome(
            token: token,
            startedAt: started,
            finishedAt: Date(),
            status: "exited",
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr,
            errorText: nil
        )
    } catch let error as FloeError {
        return ClientOutcome(
            token: token, startedAt: started, finishedAt: Date(),
            status: error == .cancelled ? "cancelled" : "error",
            exitCode: nil, stdout: "", stderr: "",
            errorText: "\(error)"
        )
    } catch {
        return ClientOutcome(
            token: token, startedAt: started, finishedAt: Date(),
            status: "error", exitCode: nil, stdout: "", stderr: "",
            errorText: "\(error)"
        )
    }
}

// MARK: - report

final class Report: @unchecked Sendable {
    private let lock = NSLock()
    private var scenarios: [[String: Any]] = []
    private var failures = 0
    private var rawLog: [String] = []

    func note(_ line: String) {
        lock.lock()
        rawLog.append(line)
        lock.unlock()
        print(line)
    }

    func fail(_ message: String) {
        lock.lock()
        failures += 1
        rawLog.append("FAIL: \(message)")
        lock.unlock()
        print("FAIL: \(message)")
    }

    func record(scenario: String, passed: Bool, details: [String: Any]) {
        lock.lock()
        scenarios.append([
            "scenario": scenario,
            "passed": passed,
            "details": details,
        ])
        if !passed { failures += 1 }
        lock.unlock()
        print("\(passed ? "PASS" : "FAIL")  \(scenario)")
    }

    var failureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }

    func json(scenarioCount: Int) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return [
            "schema": "floe-tinyemu-multiclient-check/v1",
            "harness": "FloeAgent/Qualification/TinyEMULinux/multiclient/MultiClientChannelCheck.swift",
            "scenarios": scenarios,
            "scenarioCount": scenarioCount,
            "failures": failures,
            "rawLog": rawLog,
        ]
    }
}

// MARK: - checks

@main
struct MultiClientCheck {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 4 else {
            FileHandle.standardError.write(Data("usage: multiclient-check <floe-exec> <work dir> <json out>\n".utf8))
            exit(2)
        }
        let runnerPath = arguments[1]
        let workRoot = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let jsonOut = URL(fileURLWithPath: arguments[3])
        let report = Report()
        do {
            try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("cannot create work dir: \(error)\n".utf8))
            exit(2)
        }

        report.note("runner: \(runnerPath)")
        report.note("work: \(workRoot.path)")

        await overlapScenario(report: report, runnerPath: runnerPath, workRoot: workRoot)
        await duplicateCallerIDScenario(report: report, runnerPath: runnerPath, workRoot: workRoot)
        await identityScenario(report: report, runnerPath: runnerPath, workRoot: workRoot)
        await cancelScenario(report: report, runnerPath: runnerPath, workRoot: workRoot)
        await invalidDestinationScenario(report: report, runnerPath: runnerPath, workRoot: workRoot)
        await stopWhileActiveScenario(report: report, runnerPath: runnerPath, workRoot: workRoot)
        await sharedPathScenario(report: report, runnerPath: runnerPath, workRoot: workRoot)
        await ptySessionScenario(report: report, runnerPath: runnerPath, workRoot: workRoot)

        let payload = report.json(scenarioCount: 8)
        do {
            let data = try JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: jsonOut)
            report.note("wrote \(jsonOut.path)")
        } catch {
            FileHandle.standardError.write(Data("cannot write JSON: \(error)\n".utf8))
            exit(2)
        }
        let failures = report.failureCount
        print("multiclient check: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }

    /// Two clients whose CALLER-side identity is byte-identical (the same
    /// provider call id, the same model-facing label) must still be routed
    /// independently: the transport issues a fresh token per execution, so
    /// neither output nor cancellation can collide. The commands are also
    /// byte-identical and use a mutual barrier, so a wrong "unique identity"
    /// assumption is visible as crossed markers or a serialized run.
    static func duplicateCallerIDScenario(report: Report, runnerPath: String, workRoot: URL) async {
        let dir = workRoot.appendingPathComponent("duplicate-ids", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let console: RunnerConsole
        do { console = try RunnerConsole(runnerPath: runnerPath) } catch {
            report.record(scenario: "duplicate_caller_ids_do_not_collide", passed: false, details: ["error": "\(error)"])
            return
        }
        let channel = LinuxGuestCommandChannel(transport: console, limits: .standard)
        let slots = ["one", "two"]
        let gate = slots.map { "[ -f \(dir.path)/id.\($0) ]" }.joined(separator: " && ")

        // Both clients present the SAME caller identity string and the same
        // command text; only the transport token differs.
        func command(_ slot: String) -> String {
            """
            printf 'CALL_ID=call_1 SLOT=\(slot)\\n'
            touch \(dir.path)/id.\(slot)
            i=0
            while [ $i -lt 150 ]; do
              \(gate) && break
              i=$((i+1)); sleep 0.1
            done
            if \(gate); then
              printf 'CALL_ID=call_1 OWNER=\(slot) PID=%s\\n' $$
            else
              printf 'NO_PEER_\(slot)\\n'
              exit 7
            fi
            """
        }
        let startedAt = Date()
        let outcomes = await withTaskGroup(of: ClientOutcome.self) { group in
            for slot in slots {
                group.addTask {
                    // Identical caller-provided name for both clients.
                    await runClient(channel, token: "call_1", command: command(slot), cwd: dir.path, timeout: 60)
                }
            }
            var collected: [ClientOutcome] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }
        let total = Date().timeIntervalSince(startedAt)
        let execTokens = TestTokens.execTokens(in: console)
        var ok = outcomes.count == 2 && Set(execTokens).count == 2
        if !ok {
            report.fail("duplicate-ids: expected two distinct transport tokens, saw \(execTokens)")
        }
        for outcome in outcomes {
            if outcome.exitCode != 0 || outcome.status != "exited" {
                ok = false
                report.fail("duplicate-ids: a client did not exit 0 (\(outcome.status))")
            }
            if !outcome.stdout.contains("OWNER=one") && !outcome.stdout.contains("OWNER=two") {
                ok = false
                report.fail("duplicate-ids: client missing its own owner marker")
            }
            if outcome.stdout.contains("NO_PEER") {
                ok = false
                report.fail("duplicate-ids: the mutual barrier timed out — clients did not overlap")
            }
        }
        let owners = outcomes.flatMap { outcome in
            ["OWNER=one", "OWNER=two"].filter { outcome.stdout.contains($0) }
        }
        if Set(owners) != ["OWNER=one", "OWNER=two"] {
            ok = false
            report.fail("duplicate-ids: owner markers crossed or were lost: \(owners)")
        }
        if total >= 5 {
            ok = false
            report.fail("duplicate-ids: total wall time \(total)s indicates serialization")
        }
        report.record(scenario: "duplicate_caller_ids_do_not_collide", passed: ok, details: [
            "callerIdentity": "call_1 (identical for both clients)",
            "transportTokens": execTokens,
            "totalWallSeconds": total,
            "clients": outcomes.map { [
                "status": $0.status,
                "exit": $0.exitCode.map { Int($0) } as Any,
                "stdout": $0.stdout,
            ] as [String: Any] },
        ])
        await console.close()
        console.terminateNow()
    }

    /// Three clients (parent + two children) with a mutual start-file barrier.
    /// Each client drops its own start file and only prints its success marker
    /// after ALL THREE exist; a serialized console cannot pass because the
    /// first client expires into a distinct NO_OVERLAP marker and exit 7.
    static func overlapScenario(report: Report, runnerPath: String, workRoot: URL) async {
        let dir = workRoot.appendingPathComponent("overlap", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let console: RunnerConsole
        do { console = try RunnerConsole(runnerPath: runnerPath) } catch {
            report.record(scenario: "overlap_parent_two_children", passed: false, details: ["error": "\(error)"])
            return
        }
        let channel = LinuxGuestCommandChannel(transport: console, limits: .standard)
        let names = ["parent", "child1", "child2"]
        let startGate = names.map { "[ -f \(dir.path)/start.\($0) ]" }.joined(separator: " && ")

        func command(_ name: String) -> String {
            """
            printf 'MC_ID_\(name)\\n'
            echo "\(name) started"
            touch \(dir.path)/start.\(name)
            i=0
            while [ $i -lt 150 ]; do
              \(startGate) && break
              i=$((i+1)); sleep 0.1
            done
            if \(startGate); then
              sleep 0.4
              printf 'MC_\(name)_OVERLAP_%s\\n' OK
            else
              printf 'MC_\(name)_NO_OVERLAP\\n'
              exit 7
            fi
            """
        }

        let startedAt = Date()
        let outcomes = await withTaskGroup(of: ClientOutcome.self) { group in
            for name in names {
                group.addTask {
                    await runClient(
                        channel, token: name, command: command(name),
                        cwd: dir.path, timeout: 60
                    )
                }
            }
            var collected: [ClientOutcome] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }
        let total = Date().timeIntervalSince(startedAt)

        var ok = outcomes.count == 3
        var details: [String: Any] = [
            "totalWallSeconds": total,
            "clients": outcomes.map { outcome in
                [
                    "token": outcome.token,
                    "status": outcome.status,
                    "exit": outcome.exitCode.map { Int($0) } as Any,
                    "elapsed": outcome.elapsed,
                    "stdout": outcome.stdout,
                    "stderr": outcome.stderr,
                ] as [String: Any]
            },
        ]
        for outcome in outcomes {
            if outcome.status != "exited" || outcome.exitCode != 0 {
                ok = false
                report.fail("overlap: client \(outcome.token) did not exit 0 (status=\(outcome.status) exit=\(String(describing: outcome.exitCode)) err=\(outcome.errorText ?? "-"))")
            }
            if !outcome.stdout.contains("MC_\(outcome.token)_OVERLAP_OK") {
                ok = false
                report.fail("overlap: client \(outcome.token) missing its overlap marker")
            }
            if outcome.stdout.contains("NO_OVERLAP") {
                ok = false
                report.fail("overlap: client \(outcome.token) barrier timed out — the channel serialized clients")
            }
            for other in names where other != outcome.token {
                if outcome.stdout.contains("MC_ID_\(other)") {
                    ok = false
                    report.fail("overlap: client \(outcome.token) saw \(other)'s identity — cross-talk")
                }
            }
        }
        // All three must complete within one sleep window of each other; a
        // serialized run takes at least three barrier windows and fails above.
        if let last = outcomes.map(\.finishedAt).max(), let first = outcomes.map(\.finishedAt).min(),
           last.timeIntervalSince(first) > 5 {
            ok = false
            report.fail("overlap: client completion times are not temporally colocated")
        }
        if total >= 6 {
            ok = false
            report.fail("overlap: total wall time \(total)s indicates serialization")
        }
        if let last = outcomes.map(\.finishedAt).max(),
           let first = outcomes.map(\.finishedAt).min() {
            details["completionSpreadSeconds"] = last.timeIntervalSince(first)
        }
        report.record(scenario: "overlap_parent_two_children", passed: ok, details: details)
        report.note("overlap diagnostics: \(console.diagnostics.suffix(400))")
        await console.close()
        console.terminateNow()
    }

    /// Identity/cwd/stdout/stderr/exit separation across three concurrent
    /// clients, plus environment non-leakage to a later client.
    static func identityScenario(report: Report, runnerPath: String, workRoot: URL) async {
        let base = workRoot.appendingPathComponent("identity", isDirectory: true)
        let dirA = base.appendingPathComponent("alpha", isDirectory: true)
        let dirB = base.appendingPathComponent("beta", isDirectory: true)
        let dirC = base.appendingPathComponent("gamma", isDirectory: true)
        for directory in [dirA, dirB, dirC] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let console: RunnerConsole
        do { console = try RunnerConsole(runnerPath: runnerPath) } catch {
            report.record(scenario: "identity_cwd_streams_exit", passed: false, details: ["error": "\(error)"])
            return
        }
        let channel = LinuxGuestCommandChannel(transport: console, limits: .standard)

        async let alpha = runClient(
            channel, token: "alpha",
            command: "export FLOE_MC_VAR=AAA; pwd; printf 'ALPHA_OUT\\n'; printf 'ALPHA_ERR\\n' >&2; printf 'ALPHA_VAR=%s\\n' \"$FLOE_MC_VAR\"; exit 0",
            cwd: dirA.path, timeout: 30
        )
        async let beta = runClient(
            channel, token: "beta",
            command: "pwd; printf 'BETA_OUT\\n'; printf 'BETA_ERR\\n' >&2; printf 'BETA_VAR=%s\\n' \"${FLOE_MC_VAR-unset}\"; exit 3",
            cwd: dirB.path, timeout: 30
        )
        async let gamma = runClient(
            channel, token: "gamma",
            command: "pwd; printf 'GAMMA_OUT\\n'; exit 7",
            cwd: dirC.path, timeout: 30
        )
        let (outcomeAlpha, outcomeBeta, outcomeGamma) = await (alpha, beta, gamma)
        let outcomes = [outcomeAlpha, outcomeBeta, outcomeGamma]
        var ok = true
        let byToken = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.token, $0) })

        if let alpha = byToken["alpha"] {
            ok = check(report, ok, "alpha exit 0", alpha.exitCode == 0)
            ok = check(report, ok, "alpha stdout has its own cwd", alpha.stdout.contains(dirA.path))
            ok = check(report, ok, "alpha stdout has its own marker", alpha.stdout.contains("ALPHA_OUT"))
            ok = check(report, ok, "alpha stdout has its own env", alpha.stdout.contains("ALPHA_VAR=AAA"))
            ok = check(report, ok, "alpha stderr separated", alpha.stderr.contains("ALPHA_ERR") && !alpha.stderr.contains("BETA_ERR"))
            ok = check(report, ok, "alpha stdout free of other clients", !alpha.stdout.contains("BETA_") && !alpha.stdout.contains("GAMMA_"))
        } else { ok = false; report.fail("identity: alpha missing") }
        if let beta = byToken["beta"] {
            ok = check(report, ok, "beta exit 3", beta.exitCode == 3)
            ok = check(report, ok, "beta stdout has its own cwd", beta.stdout.contains(dirB.path))
            ok = check(report, ok, "beta env did not inherit alpha's export", beta.stdout.contains("BETA_VAR=unset"))
            ok = check(report, ok, "beta stdout free of other clients", !beta.stdout.contains("ALPHA_") && !beta.stdout.contains("GAMMA_"))
        } else { ok = false; report.fail("identity: beta missing") }
        if let gamma = byToken["gamma"] {
            ok = check(report, ok, "gamma exit 7", gamma.exitCode == 7)
            ok = check(report, ok, "gamma stdout has its own cwd", gamma.stdout.contains(dirC.path))
        } else { ok = false; report.fail("identity: gamma missing") }

        // A later client must not observe another client's exported variable
        // either (environment mutations never leak between commands).
        let later = await runClient(
            channel, token: "later",
            command: "printf 'LATER_VAR=%s\\n' \"${FLOE_MC_VAR-unset}\"",
            cwd: dirA.path, timeout: 30
        )
        ok = check(report, ok, "later command env is clean", later.stdout.contains("LATER_VAR=unset"))

        report.record(scenario: "identity_cwd_streams_exit", passed: ok, details: [
            "clients": outcomes.map { [
                "token": $0.token,
                "exit": $0.exitCode.map { Int($0) } as Any,
                "stdout": $0.stdout,
                "stderr": $0.stderr,
            ] as [String: Any] },
            "later": ["stdout": later.stdout, "exit": later.exitCode.map { Int($0) } as Any],
        ])
        await console.close()
        console.terminateNow()
    }

    /// One long-running client is cancelled; the two other clients must finish
    /// with their own output, and the console must stay usable afterwards.
    static func cancelScenario(report: Report, runnerPath: String, workRoot: URL) async {
        let dir = workRoot.appendingPathComponent("cancel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let console: RunnerConsole
        do { console = try RunnerConsole(runnerPath: runnerPath) } catch {
            report.record(scenario: "cancel_one_others_finish", passed: false, details: ["error": "\(error)"])
            return
        }
        let channel = LinuxGuestCommandChannel(transport: console, limits: .standard)
        let longToken = CancellationToken()

        async let long = runClient(
            channel, token: "child-long",
            command: "printf 'LONG_STARTED\\n'; sleep 30; printf 'LONG_FINISHED\\n'",
            cwd: dir.path, cancellation: longToken, timeout: 40
        )
        async let fastOne = runClient(
            channel, token: "parent-fast",
            command: "sleep 3; printf 'PARENT_FAST_OK\\n'",
            cwd: dir.path, timeout: 40
        )
        async let fastTwo = runClient(
            channel, token: "child-fast",
            command: "sleep 3; printf 'CHILD_FAST_OK\\n'",
            cwd: dir.path, timeout: 40
        )
        try? await Task.sleep(for: .seconds(1.5))
        let cancelAt = Date()
        longToken.cancel()

        let outcomes = await [long, fastOne, fastTwo]
        let byToken = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.token, $0) })
        var ok = true
        if let long = byToken["child-long"] {
            ok = check(report, ok, "cancelled client reports cancellation", long.status == "cancelled")
            ok = check(report, ok, "cancelled client reaped promptly", long.finishedAt.timeIntervalSince(cancelAt) < 12)
            ok = check(report, ok, "cancelled client produced no completion marker", !long.stdout.contains("LONG_FINISHED"))
        } else { ok = false; report.fail("cancel: long client missing") }
        for token in ["parent-fast", "child-fast"] {
            guard let outcome = byToken[token] else { ok = false; report.fail("cancel: \(token) missing"); continue }
            ok = check(report, ok, "\(token) finished with exit 0", outcome.exitCode == 0 && outcome.status == "exited")
            ok = check(report, ok, "\(token) kept its own marker", outcome.stdout.contains(token == "parent-fast" ? "PARENT_FAST_OK" : "CHILD_FAST_OK"))
            ok = check(report, ok, "\(token) did not see the cancelled client's output", !outcome.stdout.contains("LONG_STARTED"))
        }
        // The console must still serve a new client after the cancellation.
        let recovery = await runClient(
            channel, token: "post-cancel",
            command: "printf 'POST_CANCEL_%s\\n' OK",
            cwd: dir.path, timeout: 30
        )
        ok = check(report, ok, "console usable after the cancellation", recovery.exitCode == 0 && recovery.stdout.contains("POST_CANCEL_OK"))
        report.record(scenario: "cancel_one_others_finish", passed: ok, details: [
            "clients": outcomes.map { [
                "token": $0.token,
                "status": $0.status,
                "exit": $0.exitCode.map { Int($0) } as Any,
                "elapsed": $0.elapsed,
                "stdout": $0.stdout,
                "error": $0.errorText as Any,
            ] as [String: Any] },
            "recovery": ["exit": recovery.exitCode.map { Int($0) } as Any, "stdout": recovery.stdout],
        ])
        await console.close()
        console.terminateNow()
    }

    /// A missing cwd and a missing binary fail only their own client and never
    /// poison the channel for the others.
    static func invalidDestinationScenario(report: Report, runnerPath: String, workRoot: URL) async {
        let dir = workRoot.appendingPathComponent("invalid", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let console: RunnerConsole
        do { console = try RunnerConsole(runnerPath: runnerPath) } catch {
            report.record(scenario: "invalid_destination_isolated", passed: false, details: ["error": "\(error)"])
            return
        }
        let channel = LinuxGuestCommandChannel(transport: console, limits: .standard)

        let missingDirectory = dir.appendingPathComponent("does-not-exist", isDirectory: true).path
        let badCwd = await runClient(
            channel, token: "bad-cwd", command: "pwd",
            cwd: missingDirectory, timeout: 30
        )
        let badBinary = await runClient(
            channel, token: "bad-binary", command: "exec /nonexistent/floe-mc-binary",
            cwd: dir.path, timeout: 30
        )
        let survivor = await runClient(
            channel, token: "survivor",
            command: "printf 'SURVIVOR_%s\\n' OK",
            cwd: dir.path, timeout: 30
        )
        var ok = true
        ok = check(report, ok, "missing cwd fails honestly (126)", badCwd.exitCode == 126)
        ok = check(report, ok, "missing cwd error is on its own stderr", badCwd.stderr.contains("chdir"))
        ok = check(report, ok, "missing cwd did not emit the client marker", !badCwd.stdout.contains("SURVIVOR"))
        ok = check(report, ok, "missing binary fails honestly (126/127)", badBinary.exitCode == 127 || badBinary.exitCode == 126)
        ok = check(report, ok, "missing binary reports on its own stderr", !badBinary.stderr.isEmpty)
        ok = check(report, ok, "channel survived both invalid destinations", survivor.exitCode == 0 && survivor.stdout.contains("SURVIVOR_OK"))
        report.record(scenario: "invalid_destination_isolated", passed: ok, details: [
            "badCwd": ["exit": badCwd.exitCode.map { Int($0) } as Any, "stderr": badCwd.stderr, "error": badCwd.errorText as Any],
            "badBinary": ["exit": badBinary.exitCode.map { Int($0) } as Any, "stderr": badBinary.stderr, "error": badBinary.errorText as Any],
            "survivor": ["exit": survivor.exitCode.map { Int($0) } as Any, "stdout": survivor.stdout],
        ])
        await console.close()
        console.terminateNow()
    }

    /// Closing the shared console while clients are active: every active
    /// client must resolve with an honest failure (never a fake success) and
    /// the harness must not hang.
    static func stopWhileActiveScenario(report: Report, runnerPath: String, workRoot: URL) async {
        let dir = workRoot.appendingPathComponent("stop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let console: RunnerConsole
        do { console = try RunnerConsole(runnerPath: runnerPath) } catch {
            report.record(scenario: "stop_while_active_honest", passed: false, details: ["error": "\(error)"])
            return
        }
        let channel = LinuxGuestCommandChannel(transport: console, limits: .standard)

        async let long = runClient(
            channel, token: "stop-long",
            command: "printf 'STOP_LONG_STARTED\\n'; sleep 30; printf 'STOP_LONG_FINISHED\\n'",
            cwd: dir.path, timeout: 30
        )
        async let short = runClient(
            channel, token: "stop-short",
            command: "printf 'STOP_SHORT_STARTED\\n'; sleep 4; printf 'STOP_SHORT_FINISHED\\n'",
            cwd: dir.path, timeout: 30
        )
        try? await Task.sleep(for: .seconds(1))
        let closeStarted = Date()
        await console.close()
        let outcomes = await [long, short]
        let closeElapsed = Date().timeIntervalSince(closeStarted)
        let byToken = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.token, $0) })
        var ok = true
        for token in ["stop-long", "stop-short"] {
            guard let outcome = byToken[token] else { ok = false; report.fail("stop: \(token) missing"); continue }
            if outcome.status == "exited" && outcome.exitCode == 0 {
                // A success claim requires the completion marker to have been
                // produced by the guest before the console closed.
                ok = check(report, ok, "\(token) success only with its real completion", outcome.stdout.contains("FINISHED"))
            } else {
                ok = check(report, ok, "\(token) reports honest failure, not success", outcome.errorText != nil || outcome.exitCode != 0)
            }
            ok = check(report, ok, "\(token) resolved within the close window", outcome.elapsed < 25)
        }
        ok = check(report, ok, "close returned promptly", closeElapsed < 10)
        let after = await runClient(
            channel, token: "after-close", command: "printf 'AFTER_CLOSE\\n'",
            cwd: dir.path, timeout: 10
        )
        ok = check(report, ok, "a closed channel refuses new clients honestly", after.exitCode == nil || after.status != "exited")
        report.record(scenario: "stop_while_active_honest", passed: ok, details: [
            "closeSeconds": closeElapsed,
            "clients": outcomes.map { [
                "token": $0.token,
                "status": $0.status,
                "exit": $0.exitCode.map { Int($0) } as Any,
                "stdout": $0.stdout,
                "error": $0.errorText as Any,
            ] as [String: Any] },
            "afterClose": ["status": after.status, "error": after.errorText as Any],
        ])
        console.terminateNow()
    }

    /// Concurrent unsynchronized writers to one host file: record the physical
    /// outcome. The VM layer runs real processes; coordination of same-target
    /// writes is the runtime mutation lease's responsibility, so this check
    /// records what the layer actually does instead of claiming coordination.
    static func sharedPathScenario(report: Report, runnerPath: String, workRoot: URL) async {
        let dir = workRoot.appendingPathComponent("shared", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("contended.txt")
        try? FileManager.default.removeItem(at: target)
        let console: RunnerConsole
        do { console = try RunnerConsole(runnerPath: runnerPath) } catch {
            report.record(scenario: "shared_path_physical_semantics", passed: false, details: ["error": "\(error)"])
            return
        }
        let channel = LinuxGuestCommandChannel(transport: console, limits: .standard)
        let bytes = 8192
        func writer(_ letter: String) -> String {
            """
            i=0
            while [ $i -lt \(bytes) ]; do printf '\(letter)'; i=$((i+1)); done > \(target.path)
            printf 'WROTE_\(letter)\\n'
            """
        }
        async let clientA = runClient(channel, token: "writer-a", command: writer("A"), cwd: dir.path, timeout: 30)
        async let clientB = runClient(channel, token: "writer-b", command: writer("B"), cwd: dir.path, timeout: 30)
        let (outcomeA, outcomeB) = await (clientA, clientB)
        let outcomes = [outcomeA, outcomeB]
        let finalData = (try? Data(contentsOf: target)) ?? Data()
        let uniqueBytes = Set(finalData)
        let classification: String
        switch (finalData.count, uniqueBytes) {
        case (bytes, [65]): classification = "complete-A"
        case (bytes, [66]): classification = "complete-B"
        default: classification = "mixed-or-truncated"
        }
        var ok = outcomes.allSatisfy { $0.exitCode == 0 }
        if !ok { report.fail("shared: a writer did not exit 0 (a=\(String(describing: outcomeA.exitCode)) b=\(String(describing: outcomeB.exitCode)) err=\(outcomeA.errorText ?? outcomeB.errorText ?? "-"))") }
        // Both writers ran (their own markers exist); the final file is
        // whatever the OS produced. The check records the outcome and the
        // fact that no cross-talk appeared in either client's stdout.
        for outcome in outcomes {
            ok = check(report, ok, "\(outcome.token) marker present", outcome.stdout.contains("WROTE_"))
        }
        report.record(scenario: "shared_path_physical_semantics", passed: ok, details: [
            "target": target.path,
            "finalBytes": finalData.count,
            "classification": classification,
            "note": "unsynchronized writers at the VM layer; same-target coordination is enforced by the runtime mutation lease (FloeTools MutationLeaseCoordinator), not by the guest console",
            "clients": outcomes.map { ["token": $0.token, "exit": $0.exitCode.map { Int($0) } as Any, "stdout": $0.stdout, "error": $0.errorText as Any] as [String: Any] },
        ])
        await console.close()
        console.terminateNow()
    }

    /// Two concurrent PTY sessions with per-token input and output.
    static func ptySessionScenario(report: Report, runnerPath: String, workRoot: URL) async {
        let dir = workRoot.appendingPathComponent("pty", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let console: RunnerConsole
        do { console = try RunnerConsole(runnerPath: runnerPath) } catch {
            report.record(scenario: "concurrent_pty_sessions", passed: false, details: ["error": "\(error)"])
            return
        }
        let channel = LinuxGuestCommandChannel(transport: console, limits: .standard)
        var ok = true
        do {
            let sessionA = try await channel.openSession(
                sessionID: "sess-a", argv: ["/bin/sh"], workingDirectory: dir.path, columns: 80, rows: 24
            )
            let sessionB = try await channel.openSession(
                sessionID: "sess-b", argv: ["/bin/sh"], workingDirectory: dir.path, columns: 80, rows: 24
            )
            try await sessionA.write("printf 'PTY_A_%s\\n' OK\n")
            try await sessionB.write("printf 'PTY_B_%s\\n' OK\n")
            func collect(_ session: LinuxGuestInteractiveSession, needle: String) async -> String {
                var text = ""
                let deadline = Date().addingTimeInterval(15)
                while Date() < deadline, !text.contains(needle) {
                    if let chunk = await session.nextOutput(timeoutMs: 500) {
                        text += String(decoding: chunk, as: UTF8.self)
                    } else if await session.isFinished {
                        break
                    }
                }
                return text
            }
            async let textA = collect(sessionA, needle: "PTY_A_OK")
            async let textB = collect(sessionB, needle: "PTY_B_OK")
            let (a, b) = await (textA, textB)
            ok = check(report, ok, "session A received only its own output", a.contains("PTY_A_OK") && !a.contains("PTY_B_OK"))
            ok = check(report, ok, "session B received only its own output", b.contains("PTY_B_OK") && !b.contains("PTY_A_OK"))
            await sessionA.close()
            await sessionB.close()
            report.record(scenario: "concurrent_pty_sessions", passed: ok, details: [
                "sessionA": a.suffix(400),
                "sessionB": b.suffix(400),
            ])
        } catch {
            report.record(scenario: "concurrent_pty_sessions", passed: false, details: ["error": "\(error)"])
        }
        await console.close()
        console.terminateNow()
    }

    @discardableResult
    static func check(_ report: Report, _ current: Bool, _ label: String, _ condition: Bool) -> Bool {
        if !condition { report.fail(label) }
        return current && condition
    }
}
