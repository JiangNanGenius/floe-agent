// FloeExecutionTests — typed supervisor control channel (protocol 4).
//
// These tests drive the REAL `LinuxGuestCommandChannel` router and the typed
// `LinuxGuestProjectSupervisor` client over a scripted console — no guest
// image, no second framer. They prove:
//
//  * identity wrappers mirror the guest validators (no frame-terminator or
//    ".." injection, exact width grammar);
//  * PROJOPEN travels as header + base64 CHUNKs + RUN using the existing
//    wire codec, with [projectID, generation] on the header line;
//  * exit 3/125/126/127 map to typed errors (never success), and the
//    emit_failure shape (BEGIN + ERR + END) parses identically;
//  * a positive ack is required before the console index is returned, and a
//    stale ack naming another project/generation is discarded;
//  * cancelling an open keeps the explicit uncertain-outcome contract and
//    never sends the raw 0x03 interrupt-all;
//  * EVENT notices are observed asynchronously, never hijack a runner
//    output section, and are fenced by the router generation;
//  * the protocol-3 command path is byte-stable on a data channel.

import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeExecution

// MARK: - Scripted console

/// Scripted console for the supervisor tests. Replies are queued per frame
/// name; each entry builds its chunks from the triggering frame's token, so
/// replies can embed it exactly like the guest does.
private final class SupervisorTestConsole: LinuxGuestConsoleTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<Data>.Continuation
    private let stream: AsyncStream<Data>
    private var queues: [String: [(String) -> [Data]]] = [:]
    private var writtenBytes: [UInt8] = []

    init() {
        var captured: AsyncStream<Data>.Continuation!
        self.stream = AsyncStream { captured = $0 }
        self.continuation = captured
    }

    func enqueue(_ name: String, _ build: @escaping @Sendable (String) -> [Data]) {
        lock.lock()
        queues[name, default: []].append(build)
        lock.unlock()
    }

    var written: [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return writtenBytes
    }

    var writtenText: String { String(decoding: written, as: UTF8.self) }

    func output() async -> AsyncStream<Data> { stream }

    func write(_ bytes: [UInt8]) async throws {
        let replies = record(bytes)
        for reply in replies {
            for chunk in reply {
                continuation.yield(chunk)
            }
        }
    }

    func close() async { continuation.finish() }

    /// Injects console bytes directly (asynchronous guest notices).
    func push(_ chunks: [Data]) {
        for chunk in chunks { continuation.yield(chunk) }
    }

    private func record(_ bytes: [UInt8]) -> [[Data]] {
        lock.lock()
        defer { lock.unlock() }
        writtenBytes.append(contentsOf: bytes)
        guard let frame = Self.lastFrame(in: bytes),
              var queue = queues[frame.name], !queue.isEmpty else { return [] }
        let build = queue.removeFirst()
        queues[frame.name] = queue
        return [build(frame.token)]
    }

    /// Name and token of the LAST FLOE frame in `bytes` (chunked transfers
    /// write CHUNK frames after the header).
    static func lastFrame(in bytes: [UInt8]) -> (name: String, token: String)? {
        let text = String(decoding: bytes, as: UTF8.self)
        guard let mark = text.range(of: "\u{1e}FLOE-", options: .backwards) else { return nil }
        let body = text[mark.upperBound...]
        let name = body.prefix { $0 != " " && $0 != "\u{1e}" }
        guard !name.isEmpty else { return nil }
        var remainder = body.dropFirst(name.count)
        guard remainder.first == " " else { return (String(name), "") }
        remainder = remainder.dropFirst()
        let token = remainder.prefix { $0 != " " && $0 != "\u{1e}" && $0 != "\n" }
        return (String(name), String(token))
    }
}

// MARK: - Reply builders (guest wire shapes)

private func supervisorCaps(_ token: String, protocolVersion: Int = 4) -> [Data] {
    [Data("\u{1e}FLOE-CAPS \(token) runner=floe-supervisor/1.0.0 protocol=\(protocolVersion) projects=8 tasks=8 sessions=4 base=/mnt/base state=/mnt/state net=up\u{1e}\u{1e}FLOE-END \(token) 0\u{1e}".utf8)]
}

private func runner3Caps(_ token: String) -> [Data] {
    [Data("\u{1e}FLOE-CAPS \(token) runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4\u{1e}\u{1e}FLOE-END \(token) 0\u{1e}".utf8)]
}

private func openAck(_ token: String, project: String = "proj1", generation: String = "7",
                     console: Int = 3) -> [Data] {
    [Data(("\u{1e}FLOE-BEGIN \(token)\u{1e}"
        + "\u{1e}FLOE-OUT \(token)\u{1e}"
        + "project=\(project) generation=\(generation) console=hvc\(console) "
        + "root=/mnt/state/projects/\(project)/root workspace=/workspace share=floe-ws\n"
        + "\u{1e}FLOE-END \(token) 0\u{1e}").utf8)]
}

private func endOnly(_ token: String, _ code: Int) -> [Data] {
    [Data("\u{1e}FLOE-END \(token) \(code)\u{1e}".utf8)]
}

/// The guest's emit_failure shape: BEGIN + ERR(reason) + END(code).
private func failureShape(_ token: String, _ code: Int, reason: String) -> [Data] {
    [Data("\u{1e}FLOE-BEGIN \(token)\u{1e}\u{1e}FLOE-ERR \(token)\u{1e}\(reason)\u{1e}FLOE-END \(token) \(code)\u{1e}".utf8)]
}

// MARK: - Helpers

private func boundedFirst<E: Sendable>(_ stream: AsyncStream<E>, timeout: TimeInterval = 3) async -> E? {    await withTaskGroup(of: E?.self) { group in
        group.addTask {
            for await element in stream { return element }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(timeout))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

private func waitUntil(_ deadline: TimeInterval = 5, _ condition: @Sendable () -> Bool) async {
    let end = Date().addingTimeInterval(deadline)
    while Date() < end {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - Tests

/// Lock-backed box for the @Sendable event observer capture below.
private final class EventObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) {
        lock.lock(); values.append(value); lock.unlock()
    }
    var snapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

final class LinuxGuestProjectSupervisorTests: XCTestCase {

    func testControlResponseSurvivesSeparateTextAndSplitMarkers() throws {
        let token = "split-control"
        let text = String(repeating: "完整回执", count: 1_000)
        let wire = Data(("\u{1e}FLOE-BEGIN \(token)\u{1e}"
            + "\u{1e}FLOE-OUT \(token)\u{1e}" + text
            + "\u{1e}FLOE-END \(token) 0\u{1e}").utf8)
        var parser = LinuxGuestFraming.ControlParser(token: token)
        var finished = false
        for offset in stride(from: 0, to: wire.count, by: 17) {
            let progress = parser.feed(Data(wire[offset..<min(offset + 17, wire.count)]))
            if case .finished(let exit) = progress { XCTAssertEqual(exit, 0); finished = true }
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(parser.textString, text)
    }

    func testOpenAckRequiresTheReservedMountedShare() throws {
        let project = try LinuxGuestProjectID("proj1")
        let generation = try LinuxGuestProjectGeneration("7")
        for line in [
            "project=proj1 generation=7 console=hvc1 root=/mnt/state/projects/proj1/root workspace=/workspace share=private",
            "project=proj1 generation=7 console=hvc2 root=/mnt/state/projects/proj1/root workspace=/workspace share=floe-ws"
        ] {
            XCTAssertThrowsError(try LinuxGuestProjectSupervisor.parseOpenAck(
                line, projectID: project, generation: generation, shareSlot: 0))
        }
        for slot in [-1, 8] {
            XCTAssertThrowsError(try LinuxGuestProjectWorkspaceMount(directory: "/workspace", shareSlot: slot))
        }
    }

    // MARK: identity grammar mirrors the guest validators

    func testIdentityWrappersMirrorGuestValidators() throws {
        // Valid project IDs.
        for valid in ["a", "A1", "proj1", "a.b-c_d", String(repeating: "x", count: 64)] {
            XCTAssertNoThrow(try LinuxGuestProjectID(valid), "expected valid projectID '\(valid)'")
        }
        // Invalid: empty, '..', embedded dotdot, slash, space, control byte,
        // leading punctuation, non-ASCII, oversize.
        for invalid in ["", "..", "a..b", "/abs", "a/b", "a b", "a\u{1e}b", "-lead", ".lead", "_lead", "é", String(repeating: "x", count: 65)] {
            XCTAssertThrowsError(try LinuxGuestProjectID(invalid)) { error in
                guard case LinuxGuestProjectSupervisorError.invalidIdentity(let field, _) = error else {
                    return XCTFail("unexpected error for '\(invalid)': \(error)")
                }
                XCTAssertEqual(field, "projectID")
            }
        }
        // Task ID: same grammar, wider bound.
        XCTAssertNoThrow(try LinuxGuestProjectTaskID(String(repeating: "t", count: 96)))
        XCTAssertThrowsError(try LinuxGuestProjectTaskID(String(repeating: "t", count: 97)))
        XCTAssertThrowsError(try LinuxGuestProjectTaskID("bad..task"))
        // Generation: strict decimal u64 text; "0" is real.
        for valid in ["0", "1", "42", "18446744073709551615"] {
            let generation = try LinuxGuestProjectGeneration(valid)
            XCTAssertEqual(generation.value, UInt64(valid))
        }
        for invalid in ["", "abc", "-1", "+1", "1 ", " 1", "1.5", String(repeating: "1", count: 21), "18446744073709551616"] {
            XCTAssertThrowsError(try LinuxGuestProjectGeneration(invalid), "expected invalid generation '\(invalid)'")
        }
    }

    // MARK: capabilities

    func testCapabilitiesParsesOnlyGuestReturnedValues() async throws {
        let console = SupervisorTestConsole()
        console.enqueue("HELLO") { supervisorCaps($0) }
        let supervisor = LinuxGuestProjectSupervisor(transport: console)
        let capabilities = try await supervisor.capabilities(timeout: 5)
        XCTAssertEqual(capabilities.protocolVersion, 4)
        XCTAssertEqual(capabilities.maximumProjects, 8)
        XCTAssertEqual(capabilities.maximumProjectTasks, 8)
        XCTAssertEqual(capabilities.maximumProjectSessions, 4)
        XCTAssertEqual(capabilities.baseRootfs, "/mnt/base")
        XCTAssertEqual(capabilities.stateRoot, "/mnt/state")
        XCTAssertEqual(capabilities.network, .up)
        XCTAssertTrue(capabilities.runner.hasPrefix("floe-supervisor/"))
    }

    func testCapabilitiesRefusesProtocol3Runner() async throws {
        let console = SupervisorTestConsole()
        console.enqueue("HELLO") { supervisorCaps($0, protocolVersion: 3) }
        let supervisor = LinuxGuestProjectSupervisor(transport: console)
        do {
            _ = try await supervisor.capabilities(timeout: 5)
            XCTFail("a protocol-3 CAPS answer must not be accepted as a supervisor")
        } catch LinuxGuestProjectSupervisorError.supervisorUnavailable {
            // expected
        }
    }

    // MARK: PROJOPEN wire + ack

    func testOpenUsesChunkedWireAndReturnsConsoleOnlyAfterAck() async throws {
        let console = SupervisorTestConsole()
        console.enqueue("HELLO") { supervisorCaps($0) }
        console.enqueue("PROJOPEN") { openAck($0) }
        let supervisor = LinuxGuestProjectSupervisor(transport: console)
        let result = try await supervisor.open(
            projectID: try LinuxGuestProjectID("proj1"),
            generation: try LinuxGuestProjectGeneration("7"),
            baseRootfs: "/mnt/base",
            workspaceDir: "/workspace", shareSlot: 2,
            timeout: 5
        )
        XCTAssertEqual(result.consoleIndex, 3)
        XCTAssertEqual(result.root, "/mnt/state/projects/proj1/root")
        XCTAssertEqual(result.shareSlot, 2)
        XCTAssertEqual(result.workspace, "/workspace")

        // Wire: header carries [projectID generation payloadBytes chunkCount],
        // then base64 CHUNKs, then RUN — all through the existing codec.
        let text = console.writtenText
        guard let header = text.range(of: "\u{1e}FLOE-PROJOPEN ") else {
            return XCTFail("PROJOPEN header was not written")
        }
        let headerLine = text[header.lowerBound...]
        XCTAssertTrue(headerLine.hasPrefix("\u{1e}FLOE-PROJOPEN "), "header shape")
        XCTAssertTrue(headerLine.contains(" proj1 7 "), "header carries project + generation")
        XCTAssertTrue(text.contains("\u{1e}FLOE-CHUNK "), "payload travels chunked")
        XCTAssertTrue(text.contains("\u{1e}FLOE-RUN "), "chunked transfer ends with RUN")

        // Decode the field table from the CHUNK payload: exactly
        // [baseRootfs, workspaceDir].
        guard let chunkMark = text.range(of: "\u{1e}FLOE-CHUNK ") else {
            return XCTFail("no CHUNK written")
        }
        let chunkBody = text[chunkMark.upperBound...]
        let chunkFields = chunkBody.prefix(while: { $0 != "\u{1e}" })
            .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard chunkFields.count == 3, !chunkFields[0].isEmpty, chunkFields[1] == "0",
              let decoded = Data(base64Encoded: String(chunkFields[2])) else {
            return XCTFail("CHUNK must contain its token, index zero and valid base64 payload")
        }
        var offset = 0
        func readU32() -> UInt32? {
            guard offset + 4 <= decoded.count else { return nil }
            var value: UInt32 = 0
            for byte in decoded[offset..<(offset + 4)] {
                value = (value << 8) | UInt32(byte)
            }
            offset += 4
            return value
        }
        func readField() -> String? {
            guard let count = readU32(), offset + Int(count) <= decoded.count else { return nil }
            let field = String(decoding: decoded[offset..<(offset + Int(count))], as: UTF8.self)
            offset += Int(count)
            return field
        }
        guard let fieldCount = readU32(), fieldCount == 3,
              let base = readField(), base == "/mnt/base",
              let workspace = readField(), workspace == "/workspace",
              let slot = readField(), slot == "2", offset == decoded.count else {
            return XCTFail("PROJOPEN payload is not the [baseRootfs, workspaceDir, nativeShareSlot] field table")
        }
    }

    func testOpenExitMappingNeverSucceeds() async throws {
        // 127 refused (e.g. already open / base mismatch)
        let refusedConsole = SupervisorTestConsole()
        refusedConsole.enqueue("HELLO") { supervisorCaps($0) }
        refusedConsole.enqueue("PROJOPEN") { endOnly($0, 127) }
        let refusedSupervisor = LinuxGuestProjectSupervisor(transport: refusedConsole)
        do {
            _ = try await refusedSupervisor.open(
                projectID: try LinuxGuestProjectID("proj1"),
                generation: try LinuxGuestProjectGeneration("7"),
                baseRootfs: "/mnt/base", workspaceDir: "", shareSlot: 2, timeout: 5)
            XCTFail("END 127 must not be a successful open")
        } catch LinuxGuestProjectSupervisorError.refused {
            // expected
        }

        // 125 table full (guest emit_failure shape)
        let fullConsole = SupervisorTestConsole()
        fullConsole.enqueue("HELLO") { supervisorCaps($0) }
        fullConsole.enqueue("PROJOPEN") { failureShape($0, 125, reason: "floe-supervisor: project table full") }
        let fullSupervisor = LinuxGuestProjectSupervisor(transport: fullConsole)
        do {
            _ = try await fullSupervisor.open(
                projectID: try LinuxGuestProjectID("proj2"),
                generation: try LinuxGuestProjectGeneration("1"),
                baseRootfs: "/mnt/base", workspaceDir: "", shareSlot: 2, timeout: 5)
            XCTFail("END 125 must not be a successful open")
        } catch LinuxGuestProjectSupervisorError.tableFull(let detail) {
            XCTAssertTrue(detail.contains("table full"), "guest reason preserved: \(detail)")
        }

        // 126 setup failure
        let setupConsole = SupervisorTestConsole()
        setupConsole.enqueue("HELLO") { supervisorCaps($0) }
        setupConsole.enqueue("PROJOPEN") { endOnly($0, 126) }
        let setupSupervisor = LinuxGuestProjectSupervisor(transport: setupConsole)
        do {
            _ = try await setupSupervisor.open(
                projectID: try LinuxGuestProjectID("proj3"),
                generation: try LinuxGuestProjectGeneration("1"),
                baseRootfs: "/mnt/base", workspaceDir: "", shareSlot: 2, timeout: 5)
            XCTFail("END 126 must not be a successful open")
        } catch LinuxGuestProjectSupervisorError.setupFailed {
            // expected
        }
    }

    func testOpenDiscardsStaleAckIdentity() async throws {
        let console = SupervisorTestConsole()
        console.enqueue("HELLO") { supervisorCaps($0) }
        // The guest acks END 0 but names a DIFFERENT generation: the response
        // must not mutate the newer connection.
        console.enqueue("PROJOPEN") { openAck($0, project: "proj1", generation: "8", console: 5) }
        let supervisor = LinuxGuestProjectSupervisor(transport: console)
        do {
            _ = try await supervisor.open(
                projectID: try LinuxGuestProjectID("proj1"),
                generation: try LinuxGuestProjectGeneration("7"),
                baseRootfs: "/mnt/base", workspaceDir: "", shareSlot: 2, timeout: 5)
            XCTFail("a mismatched ack must not produce a handle")
        } catch LinuxGuestProjectSupervisorError.openOutcomeUncertain(let projectID, let generation, let reason) {
            XCTAssertEqual(projectID, "proj1")
            XCTAssertEqual(generation, "7")
            XCTAssertTrue(reason.contains("responseIdentityMismatch"))
        }
    }

    func testOpenRejectsUnusableRootsBeforeAnyFrame() async throws {
        let console = SupervisorTestConsole()
        let supervisor = LinuxGuestProjectSupervisor(transport: console)
        let projectID = try LinuxGuestProjectID("proj1")
        let generation = try LinuxGuestProjectGeneration("7")
        // Relative root.
        do {
            _ = try await supervisor.open(
                projectID: projectID, generation: generation,
                baseRootfs: "mnt/base", workspaceDir: "", shareSlot: 2, timeout: 5)
            XCTFail("a relative baseRootfs must be refused")
        } catch LinuxGuestProjectSupervisorError.invalidRoot(let field, _) {
            XCTAssertEqual(field, "baseRootfs")
        }
        // Space and control bytes would break the in-band line.
        do {
            _ = try await supervisor.open(
                projectID: projectID, generation: generation,
                baseRootfs: "/mnt/base", workspaceDir: "/work space", shareSlot: 2, timeout: 5)
            XCTFail("a workspace with spaces must be refused")
        } catch LinuxGuestProjectSupervisorError.invalidRoot(let field, _) {
            XCTAssertEqual(field, "workspaceDir")
        }
        // Beyond the guest struct bound.
        do {
            _ = try await supervisor.open(
                projectID: projectID, generation: generation,
                baseRootfs: "/" + String(repeating: "a", count: 300), workspaceDir: "", shareSlot: 2, timeout: 5)
            XCTFail("an oversize root must be refused")
        } catch LinuxGuestProjectSupervisorError.invalidRoot {
            // expected
        }
        XCTAssertEqual(console.written, [], "validation must fail before any frame is written")
    }

    func testOpenCancellationKeepsUncertainOutcomeAndSendsNoInterrupt() async throws {
        let console = SupervisorTestConsole()
        console.enqueue("HELLO") { supervisorCaps($0) }
        // The guest never answers PROJOPEN.
        let supervisor = LinuxGuestProjectSupervisor(transport: console)
        let token = CancellationToken()
        let openTask = Task {
            try await supervisor.open(
                projectID: try LinuxGuestProjectID("proj1"),
                generation: try LinuxGuestProjectGeneration("7"),
                baseRootfs: "/mnt/base", workspaceDir: "", shareSlot: 2, timeout: 60,
                cancellation: token)
        }
        await waitUntil(5) { console.writtenText.contains("FLOE-PROJOPEN") }
        XCTAssertTrue(console.writtenText.contains("FLOE-PROJOPEN"), "the open reached the guest")
        token.cancel()
        do {
            _ = try await openTask.value
            XCTFail("a cancelled open must not succeed")
        } catch LinuxGuestProjectSupervisorError.openOutcomeUncertain(let projectID, let generation, _) {
            // The contract: never claim "uncreated"; reconcile via status/drop.
            XCTAssertEqual(projectID, "proj1")
            XCTAssertEqual(generation, "7")
        }
        XCTAssertFalse(console.written.contains(0x03), "cancelling a control waiter must never send the raw interrupt-all")
    }

    // MARK: close / drop / taskkill / lease / ping mapping

    func testLifecycleExitMapping() async throws {
        let console = SupervisorTestConsole()
        console.enqueue("HELLO") { supervisorCaps($0) }
        console.enqueue("PROJCLOSE") { endOnly($0, 3) }
        console.enqueue("PROJDROP") { endOnly($0, 127) }
        console.enqueue("TASKKILL") { endOnly($0, 3) }
        console.enqueue("LEASE") { endOnly($0, 0) }   // first LEASE: renew ok
        console.enqueue("LEASE") { endOnly($0, 3) }   // second LEASE: release -> nothing held
        console.enqueue("PING") { endOnly($0, 0) }
        let supervisor = LinuxGuestProjectSupervisor(transport: console)

        let projectID = try LinuxGuestProjectID("proj1")
        let generation = try LinuxGuestProjectGeneration("7")
        let taskID = try LinuxGuestProjectTaskID("task-1")

        do {
            try await supervisor.close(projectID: projectID, generation: generation, timeout: 5)
            XCTFail("close END 3 must be an error")
        } catch LinuxGuestProjectSupervisorError.unknownProject(let id, let gen) {
            XCTAssertEqual(id, "proj1")
            XCTAssertEqual(gen, "7")
        }

        do {
            try await supervisor.drop(projectID: projectID, generation: generation, timeout: 5)
            XCTFail("drop END 127 must be an error")
        } catch LinuxGuestProjectSupervisorError.refused {
            // expected: open or liveness record present
        }

        let killed = try await supervisor.killTask(
            projectID: projectID, generation: generation, taskID: taskID, timeout: 5)
        XCTAssertFalse(killed, "TASKKILL END 3 means nothing to kill, not success")

        try await supervisor.renewLease(
            projectID: projectID, generation: generation, leaseID: "lease-a", timeout: 5)

        let released = try await supervisor.releaseLease(
            projectID: projectID, generation: generation, leaseID: "lease-a", timeout: 5)
        XCTAssertFalse(released, "LEASE release END 3 means this holder holds nothing")

        try await supervisor.ping(timeout: 5)
    }

    func testStatusParsesProjectRows() async throws {
        let console = SupervisorTestConsole()
        console.enqueue("HELLO") { supervisorCaps($0) }
        console.enqueue("PROJSTAT") { token in
            [Data(("\u{1e}FLOE-BEGIN \(token)\u{1e}"
                + "\u{1e}FLOE-OUT \(token)\u{1e}"
                + "project=proj1 generation=7 state=active console=hvc3 runner=412 lease=held\n"
                + "project=proj2 generation=1 state=recovered console=hvc1 runner=0 lease=free\n"
                + "\u{1e}FLOE-END \(token) 0\u{1e}").utf8)]
        }
        let supervisor = LinuxGuestProjectSupervisor(transport: console)
        let records = try await supervisor.status(timeout: 5)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].projectID.rawValue, "proj1")
        XCTAssertEqual(records[0].state, .active)
        XCTAssertEqual(records[0].consoleIndex, 3)
        XCTAssertEqual(records[0].runnerPID, 412)
        XCTAssertTrue(records[0].leaseHeld)
        XCTAssertEqual(records[1].state, .recovered)
        XCTAssertEqual(records[1].runnerPID, 0)
        XCTAssertFalse(records[1].leaseHeld)
    }

    // MARK: events

    func testEventObservationThroughTheChannelRouter() async throws {
        let console = SupervisorTestConsole()
        console.enqueue("HELLO") { supervisorCaps($0) }
        console.enqueue("PING") { endOnly($0, 0) }
        let supervisor = LinuxGuestProjectSupervisor(transport: console)
        let events = await supervisor.events()
        try await supervisor.ping(timeout: 5)
        console.push([Data("\u{1e}FLOE-EVENT proj1 7 runner-died the runner exited\u{1e}".utf8)])
        let event = await boundedFirst(events)
        XCTAssertEqual(event?.projectID.rawValue, "proj1")
        XCTAssertEqual(event?.generation.rawValue, "7")
        XCTAssertEqual(event?.kind, .runnerDied)
        XCTAssertEqual(event?.detail, "the runner exited")
    }

    func testEventPumpFencesStaleGenerationAndMalformedIdentities() async throws {
        let pump = LinuxGuestSupervisorEventPump(expectedGeneration: 1)
        let (events, continuation) = AsyncStream.makeStream(of: LinuxGuestProjectEvent.self)
        await pump.install(continuation)
        await pump.onEvent(arguments: "proj1 7 runner-died boom", generation: 1)
        let live = await boundedFirst(events)
        XCTAssertEqual(live?.kind, .runnerDied)
        // Older boot: fenced, dropped and counted.
        await pump.onEvent(arguments: "proj1 7 runner-died old-boot", generation: 0)
        // Malformed identity: dropped and counted.
        await pump.onEvent(arguments: "bad..id 7 runner-died x", generation: 1)
        // Unknown kind: dropped and counted.
        await pump.onEvent(arguments: "proj1 7 brand-new-kind x", generation: 1)
        // Missing fields: dropped and counted.
        await pump.onEvent(arguments: "proj1 7", generation: 1)
        // Reconnect re-arms the fence for the new boot generation.
        await pump.setExpectedGeneration(2)
        await pump.onEvent(arguments: "proj1 9 recovered -", generation: 2)
        let recovered = await boundedFirst(events)
        XCTAssertEqual(recovered?.kind, .recovered)
        XCTAssertEqual(recovered?.detail, "", "'-' means no detail")
        let droppedCount = await pump.droppedEventCount
        XCTAssertEqual(droppedCount, 4)
    }

    // MARK: protocol-3 data channel stays byte-stable

    func testRunner3CommandOutputSurvivesAnInterleavedEvent() async throws {
        let console = SupervisorTestConsole()
        console.enqueue("HELLO") { runner3Caps($0) }
        console.enqueue("EXEC") { token in
            [Data(("\u{1e}FLOE-BEGIN \(token)\u{1e}"
                + "\u{1e}FLOE-OUT \(token)\u{1e}before"
                + "\u{1e}FLOE-EVENT proj1 7 closed host-close\u{1e}"
                + "after"
                + "\u{1e}FLOE-END \(token) 0\u{1e}").utf8)]
        }
        let channel = LinuxGuestCommandChannel(transport: console)
        let observed = EventObservationBox()
        _ = await channel.installSupervisorEventObserver { arguments, _ in
            observed.append(arguments)
        }
        let result = try await channel.run(argv: ["/bin/echo", "hi"], timeout: 5)
        XCTAssertEqual(result.exitCode, 0)
        // The EVENT frame never enters command output and never strands the
        // section: the bytes after it still belong to the command.
        XCTAssertEqual(result.stdout, "beforeafter")
        XCTAssertEqual(observed.snapshot, ["proj1 7 closed host-close"])
    }

    func testRunner3PreservesEventShapedOutputWithoutASupervisorObserver() async throws {
        let console = SupervisorTestConsole()
        console.enqueue("HELLO") { runner3Caps($0) }
        let payload = "before\u{1e}FLOE-EVENT proj1 7 closed literal-output\u{1e}after"
        console.enqueue("EXEC") { token in
            [Data(("\u{1e}FLOE-BEGIN \(token)\u{1e}"
                + "\u{1e}FLOE-OUT \(token)\u{1e}" + payload
                + "\u{1e}FLOE-END \(token) 0\u{1e}").utf8)]
        }
        let channel = LinuxGuestCommandChannel(transport: console)
        let result = try await channel.run(argv: ["/bin/echo", "hi"], timeout: 5)
        XCTAssertEqual(result.stdout, payload)
    }

    func testWrongRunnerProtocolRefusesBeforeSendingSupervisorControl() async throws {
        let console = SupervisorTestConsole()
        console.enqueue("HELLO") { runner3Caps($0) }
        let supervisor = LinuxGuestProjectSupervisor(transport: console)
        do {
            try await supervisor.ping(timeout: 5)
            XCTFail("A protocol-3 runner is not a project supervisor")
        } catch LinuxGuestProjectSupervisorError.supervisorUnavailable { }
        XCTAssertFalse(console.writtenText.contains("FLOE-PING"))
    }


    func testBoundedEventOverflowIsReported() async throws {
        let pump = LinuxGuestSupervisorEventPump(expectedGeneration: 1)
        let (events, continuation) = AsyncStream.makeStream(
            of: LinuxGuestProjectEvent.self, bufferingPolicy: .bufferingNewest(1))
        await pump.install(continuation)
        await pump.onEvent(arguments: "proj1 7 recovered -", generation: 1)
        await pump.onEvent(arguments: "proj1 7 closed -", generation: 1)
        let latest = await boundedFirst(events)
        let dropped = await pump.droppedEventCount
        XCTAssertEqual(latest?.kind, .closed)
        XCTAssertEqual(dropped, 1)
    }

}
