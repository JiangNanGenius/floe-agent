// FloeExecutionTests — production host-channel wiring for the optional
// guest → host control bridge (`floe-host`).
//
// These tests drive the real `LinuxGuestCommandChannel` over a scripted
// console: the guest frames are emitted byte-for-byte like the runner emits
// them (HELLO/CAPS, BEGIN + HOSTREQ, END), and the host replies through the
// channel's own writer. Nothing is stubbed below the channel, so the tests
// cover what the runner will actually see on device: capability
// advertisement, the bounded payload/codec, off-router processing (a second
// command still completes while a host request is blocked), cancellation
// propagation, stale-generation drops and explicit failures.

import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeExecution

// MARK: - Guest frame helpers

/// Parses `\x1eFLOE-<NAME> <token>[ arguments]\x1e` frames out of raw console
/// text, mirroring the runner's own framing.
enum HostFrames {
    struct Frame: Equatable {
        let name: String
        let token: String
        let arguments: String
    }

    private static let regex = try? NSRegularExpression(
        // Inline EXEC frames end at `\n` (no closing 0x1e), marker frames
        // end at 0x1e; both terminators are accepted and excluded here.
        pattern: "\u{1e}FLOE-([A-Z]+) ([^ \u{1e}\n]+)([^\u{1e}\n]*)"
    )

    static func frames(_ text: String) -> [Frame] {
        guard let regex else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges == 4 else { return nil }
            return Frame(
                name: ns.substring(with: match.range(at: 1)),
                token: ns.substring(with: match.range(at: 2)),
                arguments: ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
            )
        }
    }

    static func first(_ name: String, in text: String) -> Frame? {
        frames(text).first { $0.name == name }
    }

    static func all(_ name: String, in text: String) -> [Frame] {
        frames(text).filter { $0.name == name }
    }

    /// The canonical v1 control line the runner encodes for one action.
    static func requestLine(token: String, action: String, format: String, source: String, destination: String? = nil) -> String {
        var line = "v1 token=\(token) action=\(action) format=\(format) source=\(source)"
        if let destination { line += " destination=\(destination)" }
        return line
    }

    static func encoded(_ payload: String) -> String {
        Data(payload.utf8).base64EncodedString()
    }

    static func decoded(_ payload: String) -> String? {
        Data(base64Encoded: payload).map { String(decoding: $0, as: UTF8.self) }
    }
}

enum GuestFrames {
    static func caps(_ token: String, hostArchive: String = "create,extract,list,decompress") -> Data {
        Data("\u{1e}FLOE-CAPS \(token) runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4 net=up hostArchive=\(hostArchive)\u{1e}\u{1e}FLOE-END \(token) 0\u{1e}".utf8)
    }

    static func begin(_ token: String) -> Data {
        Data("\u{1e}FLOE-BEGIN \(token)\u{1e}".utf8)
    }

    static func hostRequest(_ token: String, payload: String) -> Data {
        Data("\u{1e}FLOE-HOSTREQ \(token) \(payload)\u{1e}".utf8)
    }

    static func end(_ token: String, exit: Int32) -> Data {
        Data("\u{1e}FLOE-END \(token) \(exit)\u{1e}".utf8)
    }

    static func out(_ token: String, _ text: String) -> Data {
        Data("\u{1e}FLOE-OUT \(token)\u{1e}".utf8) + Data(text.utf8)
    }
}

// MARK: - Scripted console

/// Scripted guest console: `respond` sees every host→guest frame batch and
/// returns the guest bytes to push. `push` injects frames from the test body
/// (malformed requests, cancellation reap proofs).
final class ScriptedHostConsole: LinuxGuestConsoleTransport, @unchecked Sendable {
    typealias Responder = @Sendable (Data) -> [Data]

    private let lock = NSLock()
    private let continuation: AsyncStream<Data>.Continuation
    private let stream: AsyncStream<Data>
    private var responder: Responder
    private var writtenBytes: [UInt8] = []

    init(responder: @escaping Responder) {
        var captured: AsyncStream<Data>.Continuation!
        self.stream = AsyncStream { captured = $0 }
        self.continuation = captured
        self.responder = responder
    }

    var written: [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return writtenBytes
    }

    var writtenText: String { String(decoding: written, as: UTF8.self) }

    func output() async -> AsyncStream<Data> { stream }

    func write(_ bytes: [UInt8]) async throws {
        let data = Data(bytes)
        let responder = record(data)
        for chunk in responder(data) {
            continuation.yield(chunk)
        }
    }

    /// Synchronous helper: NSLock must not be taken in an async context.
    private func record(_ data: Data) -> Responder {
        lock.lock()
        defer { lock.unlock() }
        writtenBytes.append(contentsOf: data)
        return responder
    }

    func close() async { continuation.finish() }

    /// Injects guest bytes directly (router test seam).
    func push(_ chunks: [Data]) {
        for chunk in chunks { continuation.yield(chunk) }
    }
}

/// Which EXEC token owns the bridge script: the first one that asks, and any
/// later frame for that same token.
final class BridgeTokenClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    func claim(_ candidate: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if token == nil {
            token = candidate
            return true
        }
        return token == candidate
    }

    var claimed: String? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }
}

// MARK: - Recorders

actor HostRequestRecorder {
    private(set) var requests: [LinuxGuestHostRequest] = []

    func record(_ request: LinuxGuestHostRequest) {
        requests.append(request)
    }

    func count() -> Int { requests.count }
    func first() -> LinuxGuestHostRequest? { requests.first }
}

actor HostRequestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var open = false

    func wait() async {
        if open { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        open = true
        continuation?.resume()
        continuation = nil
    }
}

/// Lock-based counter for the scripted console (which must not take a lock
/// in an async context).
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Lock-based spy for the registry-level factory (the factory itself is
/// synchronous, so it cannot write into an actor).
final class HostRequestHandlerSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var environmentID: String?
    private var pathMap: LinuxGuestPathMap?

    func record(environmentID: String, pathMap: LinuxGuestPathMap) {
        lock.lock()
        defer { lock.unlock() }
        self.environmentID = environmentID
        self.pathMap = pathMap
    }

    var recordedEnvironmentID: String? {
        lock.lock()
        defer { lock.unlock() }
        return environmentID
    }

    var recordedPathMap: LinuxGuestPathMap? {
        lock.lock()
        defer { lock.unlock() }
        return pathMap
    }
}

// MARK: - Tests

final class LinuxGuestHostChannelTests: XCTestCase {

    private let helloArgument = "archive=create,extract,list,decompress"

    /// Polls the condition on the main test task without blocking the actor.
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    private func makeChannel(
        limits: LinuxGuestLimits = .standard,
        responder: @escaping ScriptedHostConsole.Responder
    ) -> (ScriptedHostConsole, LinuxGuestCommandChannel) {
        let console = ScriptedHostConsole(responder: responder)
        let channel = LinuxGuestCommandChannel(transport: console, limits: limits)
        return (console, channel)
    }

    private func makeBridgeResponder(
        claim: BridgeTokenClaim,
        requestLine: @escaping @Sendable (String) -> String
    ) -> ScriptedHostConsole.Responder {
        { data in
            let text = String(decoding: data, as: UTF8.self)
            let frames = HostFrames.frames(text)
            if let hello = frames.first(where: { $0.name == "HELLO" }) {
                return [GuestFrames.caps(hello.token)]
            }
            if let exec = frames.first(where: { $0.name == "EXEC" }) {
                if claim.claim(exec.token) {
                    let line = requestLine(exec.token)
                    return [GuestFrames.begin(exec.token), GuestFrames.hostRequest(
                        exec.token,
                        payload: HostFrames.encoded(line)
                    )]
                }
                // A normal command on another token completes immediately, so
                // a test can prove the router keeps serving it while host work
                // is blocked.
                return [GuestFrames.begin(exec.token), GuestFrames.out(exec.token, "plain-ok"), GuestFrames.end(exec.token, exit: 0)]
            }
            if let reply = frames.first(where: { $0.name == "HOSTREPLY" }), reply.token == claim.claimed {
                // The runner reads the reply, prints it and ends the command.
                return [GuestFrames.end(reply.token, exit: 0)]
            }
            return []
        }
    }

    // MARK: advertisement

    func testHelloAdvertisesArchiveCapabilityOnlyWhenAHandlerIsInstalled() async throws {
        let (console, channel) = makeChannel { data in
            let text = String(decoding: data, as: UTF8.self)
            guard let hello = HostFrames.first("HELLO", in: text) else { return [] }
            return [GuestFrames.caps(hello.token)]
        }
        // Nothing installed: the handshake must not advertise the bridge.
        _ = try await channel.probeCapabilities(timeout: 2)
        guard let unadvertised = HostFrames.first("HELLO", in: console.writtenText) else {
            return XCTFail("no HELLO frame was sent")
        }
        XCTAssertEqual(unadvertised.arguments, "")

        // Installed: the next handshake carries the handler's own argument.
        await channel.installHostRequestHandler(
            LinuxGuestHostRequestHandler(helloArgument: helloArgument) { _, _ in "status=ok" }
        )
        let secondConsole = ScriptedHostConsole { data in
            let text = String(decoding: data, as: UTF8.self)
            guard let hello = HostFrames.first("HELLO", in: text) else { return [] }
            return [GuestFrames.caps(hello.token)]
        }
        let second = LinuxGuestCommandChannel(transport: secondConsole)
        await second.installHostRequestHandler(
            LinuxGuestHostRequestHandler(helloArgument: helloArgument) { _, _ in "status=ok" }
        )
        _ = try await second.probeCapabilities(timeout: 2)
        XCTAssertEqual(HostFrames.first("HELLO", in: secondConsole.writtenText)?.arguments, helloArgument)
    }

    // MARK: round trip

    func testHostRequestRoundTripsAndDoesNotBlockOtherCommands() async throws {
        let recorder = HostRequestRecorder()
        let gate = HostRequestGate()
        let claim = BridgeTokenClaim()
        let (console, channel) = makeChannel(responder: makeBridgeResponder(claim: claim) { token in
            HostFrames.requestLine(token: token, action: "list", format: "tgz", source: "/workspace/a.tar.gz")
        })
        let expectedReply = "status=ok action=list format=tgz entries=2 bytes=42 path=/workspace/.floe-host-archive/listing-1.txt"
        await channel.installHostRequestHandler(
            LinuxGuestHostRequestHandler(helloArgument: helloArgument) { request, _ in
                await recorder.record(request)
                await gate.wait()
                return expectedReply
            }
        )

        let bridgeRun = Task {
            try await channel.run(argv: ["floe-host", "archive", "list", "/workspace/a.tar.gz"], timeout: 10)
        }
        let recorded = await waitUntil { await recorder.count() == 1 }
        XCTAssertTrue(recorded, "the handler never saw the HOSTREQ frame")
        guard let request = await recorder.first() else { return XCTFail("no request") }
        XCTAssertEqual(request.token, claim.claimed)
        XCTAssertEqual(
            request.payload,
            HostFrames.requestLine(token: request.token, action: "list", format: "tgz", source: "/workspace/a.tar.gz")
        )

        // The host work is still blocked: the console router must keep
        // serving other tokens (a router that awaited the handler here would
        // deadlock every other command on the console).
        let plain = try await channel.run(argv: ["/bin/echo", "ok"], timeout: 5)
        XCTAssertEqual(plain.exitCode, 0)
        XCTAssertEqual(plain.stdout, "plain-ok")

        await gate.release()
        let bridgeResult = try await bridgeRun.value
        XCTAssertEqual(bridgeResult.exitCode, 0)

        guard let replyFrame = HostFrames.first("HOSTREPLY", in: console.writtenText) else {
            return XCTFail("the host never wrote a HOSTREPLY frame")
        }
        XCTAssertEqual(replyFrame.token, request.token)
        XCTAssertEqual(HostFrames.decoded(replyFrame.arguments), expectedReply)
    }

    // MARK: refusals

    func testUnknownTokenIsDroppedWithoutHandlerWorkOrReply() async throws {
        let recorder = HostRequestRecorder()
        let claim = BridgeTokenClaim()
        let (console, channel) = makeChannel(responder: { data in
            let text = String(decoding: data, as: UTF8.self)
            let frames = HostFrames.frames(text)
            if let hello = frames.first(where: { $0.name == "HELLO" }) {
                return [GuestFrames.caps(hello.token)]
            }
            if let exec = frames.first(where: { $0.name == "EXEC" }), claim.claim(exec.token) {
                // Hold the command open without sending a HOSTREQ itself.
                return [GuestFrames.begin(exec.token)]
            }
            return []
        })
        await channel.installHostRequestHandler(
            LinuxGuestHostRequestHandler(helloArgument: helloArgument) { request, _ in
                await recorder.record(request)
                return "status=ok"
            }
        )
        let run = Task { try await channel.run(argv: ["/bin/cat"], timeout: 5) }
        let started = await waitUntil { claim.claimed != nil }
        XCTAssertTrue(started)

        // A token this channel is not running (never claimed) must be
        // dropped before any handler work and must not produce a reply.
        console.push([
            GuestFrames.hostRequest(
                "unknown-token",
                payload: HostFrames.encoded(HostFrames.requestLine(token: "unknown-token", action: "list", format: "zip", source: "/workspace/x.zip"))
            )
        ])
        try await Task.sleep(for: .milliseconds(150))
        let recordedCount = await recorder.count()
        XCTAssertEqual(recordedCount, 0)
        XCTAssertTrue(HostFrames.all("HOSTREPLY", in: console.writtenText).isEmpty)

        console.push([GuestFrames.end(claim.claimed ?? "", exit: 0)])
        _ = try await run.value
    }

    func testMalformedPayloadFailsExplicitlyWithoutHandlerWork() async throws {
        let recorder = HostRequestRecorder()
        let claim = BridgeTokenClaim()
        let (console, channel) = makeChannel(responder: { data in
            let text = String(decoding: data, as: UTF8.self)
            let frames = HostFrames.frames(text)
            if let hello = frames.first(where: { $0.name == "HELLO" }) {
                return [GuestFrames.caps(hello.token)]
            }
            if let exec = frames.first(where: { $0.name == "EXEC" }), claim.claim(exec.token) {
                return [GuestFrames.begin(exec.token)]
            }
            return []
        })
        await channel.installHostRequestHandler(
            LinuxGuestHostRequestHandler(helloArgument: helloArgument) { request, _ in
                await recorder.record(request)
                return "status=ok"
            }
        )
        let run = Task { try await channel.run(argv: ["floe-host", "archive", "list", "/workspace/a.zip"], timeout: 5) }
        let started = await waitUntil { claim.claimed != nil }
        XCTAssertTrue(started)
        guard let token = claim.claimed else { return XCTFail("no bridge token") }

        // Oversized payload (base64 beyond the bounded request size).
        let oversized = String(repeating: "A", count: 5000)
        console.push([GuestFrames.hostRequest(token, payload: oversized)])
        let replied = await waitUntil {
            HostFrames.first("HOSTREPLY", in: console.writtenText) != nil
        }
        XCTAssertTrue(replied, "the host must answer a bounded failure instead of hanging the guest")
        let recordedCount = await recorder.count()
        XCTAssertEqual(recordedCount, 0)
        guard let reply = HostFrames.first("HOSTREPLY", in: console.writtenText) else { return XCTFail("no reply") }
        let decoded = HostFrames.decoded(reply.arguments)
        XCTAssertEqual(decoded, LinuxGuestHostRequestFailure.reply)
        XCTAssertTrue(decoded?.hasPrefix("status=error") == true)

        console.push([GuestFrames.end(token, exit: 125)])
        let result = try await run.value
        XCTAssertEqual(result.exitCode, 125)
    }

    func testOversizedReplyIsReplacedByABoundedFailure() async throws {
        let claim = BridgeTokenClaim()
        let (console, channel) = makeChannel(responder: makeBridgeResponder(claim: claim) { token in
            HostFrames.requestLine(token: token, action: "create", format: "zip", source: "/workspace/a", destination: "/workspace/a.zip")
        })
        await channel.installHostRequestHandler(
            LinuxGuestHostRequestHandler(helloArgument: helloArgument) { _, _ in
                String(repeating: "x", count: 5000)
            }
        )
        let run = Task {
            try await channel.run(argv: ["floe-host", "archive", "create", "--format", "zip"], timeout: 5)
        }
        let completed = await waitUntil { HostFrames.all("HOSTREPLY", in: console.writtenText).count == 1 }
        XCTAssertTrue(completed)
        guard let reply = HostFrames.first("HOSTREPLY", in: console.writtenText) else { return XCTFail("no reply") }
        guard let decoded = HostFrames.decoded(reply.arguments) else { return XCTFail("undecodable reply") }
        XCTAssertTrue(decoded.hasPrefix("status=error code=reply-too-large"), decoded)
        XCTAssertLessThanOrEqual(decoded.utf8.count, LinuxGuestHostRequestCodec.maxReplyBytes)
        _ = try await run.value
    }

    // MARK: cancellation / timeouts / stale generation

    func testInterruptCancelsHostWorkAndDropsTheLateReply() async throws {
        let recorder = HostRequestRecorder()
        let claim = BridgeTokenClaim()
        let (console, channel) = makeChannel(responder: { data in
            let text = String(decoding: data, as: UTF8.self)
            let frames = HostFrames.frames(text)
            if let hello = frames.first(where: { $0.name == "HELLO" }) {
                return [GuestFrames.caps(hello.token)]
            }
            if let exec = frames.first(where: { $0.name == "EXEC" }), claim.claim(exec.token) {
                return [GuestFrames.begin(exec.token), GuestFrames.hostRequest(
                    exec.token,
                    payload: HostFrames.encoded(HostFrames.requestLine(token: exec.token, action: "list", format: "gz", source: "/workspace/a.gz"))
                )]
            }
            if let signal = frames.first(where: { $0.name == "SIGNAL" }) {
                // Real runner reap proof after the interrupt.
                return [GuestFrames.end(signal.token, exit: 130)]
            }
            return []
        })
        await channel.installHostRequestHandler(
            LinuxGuestHostRequestHandler(helloArgument: helloArgument) { request, cancellation in
                await recorder.record(request)
                while !cancellation.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return "status=error code=cancelled detail=host request cancelled"
            }
        )
        let cancellation = CancellationToken()
        let run = Task {
            try await channel.run(argv: ["floe-host", "archive", "list", "/workspace/a.gz"], timeout: 30, cancellation: cancellation)
        }
        let recorded = await waitUntil { await recorder.count() == 1 }
        XCTAssertTrue(recorded)
        cancellation.cancel()
        do {
            _ = try await run.value
            XCTFail("expected the cancellation to surface after the guest reaped the command")
        } catch FloeError.cancelled {
            // expected
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(
            HostFrames.all("HOSTREPLY", in: console.writtenText).isEmpty,
            "a reply after END must be dropped, never written into the console"
        )
    }

    func testRouterResetDropsTheStaleGenerationReply() async throws {
        let recorder = HostRequestRecorder()
        let gate = HostRequestGate()
        let claim = BridgeTokenClaim()
        let (console, channel) = makeChannel(responder: makeBridgeResponder(claim: claim) { token in
            HostFrames.requestLine(token: token, action: "list", format: "tar", source: "/workspace/a.tar")
        })
        await channel.installHostRequestHandler(
            LinuxGuestHostRequestHandler(helloArgument: helloArgument) { request, _ in
                await recorder.record(request)
                await gate.wait()
                return "status=ok action=list format=tar entries=1 bytes=5 path=/workspace/listing.txt"
            }
        )
        let run = Task { try await channel.run(argv: ["floe-host", "archive", "list", "/workspace/a.tar"], timeout: 10) }
        let recorded = await waitUntil { await recorder.count() == 1 }
        XCTAssertTrue(recorded)

        // Reboot boundary: router state resets, the old boot's token is gone.
        await channel.resetRouterState()
        await gate.release()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(
            HostFrames.all("HOSTREPLY", in: console.writtenText).isEmpty,
            "a reply from a previous boot generation must never reach the new console"
        )
        do {
            _ = try await run.value
            XCTFail("the reset channel stream must end the waiting command honestly")
        } catch {
            // consoleUnavailable — the guest never confirmed completion.
        }
    }

    /// The reviewer-flagged race: a host timeout abandons the request, the
    /// guest retries on the same live command token, and the first handler
    /// returns late. The late completion must neither write a second reply
    /// nor remove the retry's state.
    func testTimeoutRetryKeepsTheNewRequestStateWhenTheOldHandlerReturnsLate() async throws {
        let recorder = HostRequestRecorder()
        let lateGate = HostRequestGate()
        let retryGate = HostRequestGate()
        let claim = BridgeTokenClaim()
        let replies = LockedCounter()
        let firstLine = HostFrames.requestLine(token: "placeholder", action: "list", format: "tgz", source: "/workspace/first.tgz")
        let retryLine = HostFrames.requestLine(token: "placeholder", action: "list", format: "tgz", source: "/workspace/retry.tgz")
        let (console, channel) = makeChannel(limits: LinuxGuestLimits(hostRequestTimeout: 0.4)) { data in
            let text = String(decoding: data, as: UTF8.self)
            let frames = HostFrames.frames(text)
            if let hello = frames.first(where: { $0.name == "HELLO" }) {
                return [GuestFrames.caps(hello.token)]
            }
            if let exec = frames.first(where: { $0.name == "EXEC" }), claim.claim(exec.token) {
                let payload = HostFrames.encoded(
                    HostFrames.requestLine(token: exec.token, action: "list", format: "tgz", source: "/workspace/first.tgz")
                )
                return [GuestFrames.begin(exec.token), GuestFrames.hostRequest(exec.token, payload: payload)]
            }
            if let reply = frames.first(where: { $0.name == "HOSTREPLY" }), reply.token == claim.claimed {
                // Keep the command alive for the timeout reply; the guest
                // retries with a second HOSTREQ, and the retry's reply ends it.
                if replies.increment() == 2 {
                    return [GuestFrames.end(reply.token, exit: 0)]
                }
            }
            return []
        }
        await channel.installHostRequestHandler(
            LinuxGuestHostRequestHandler(helloArgument: helloArgument) { request, cancellation in
                await recorder.record(request)
                let isFirst = await recorder.count() == 1
                if isFirst {
                    // Cancelled by the host deadline, then held until the
                    // retry is in flight before returning late.
                    while !cancellation.isCancelled {
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                    await lateGate.wait()
                    return "status=ok action=list format=tgz entries=1 bytes=1 path=/workspace/late.txt"
                }
                await retryGate.wait()
                return "status=ok action=list format=tgz entries=2 bytes=2 path=/workspace/retry.txt"
            }
        )
        let run = Task { try await channel.run(argv: ["floe-host", "archive", "list", firstLine], timeout: 10) }
        let timedOut = await waitUntil { HostFrames.all("HOSTREPLY", in: console.writtenText).count == 1 }
        XCTAssertTrue(timedOut, "the host deadline must produce a reply")
        guard let firstReply = HostFrames.first("HOSTREPLY", in: console.writtenText),
              let firstDecoded = HostFrames.decoded(firstReply.arguments) else {
            return XCTFail("no decodable timeout reply")
        }
        XCTAssertTrue(firstDecoded.hasPrefix("status=error code=host-timeout"), firstDecoded)
        guard let token = claim.claimed else { return XCTFail("no bridge token") }

        // The guest retries on the same live command token.
        console.push([GuestFrames.hostRequest(token, payload: HostFrames.encoded(retryLine))])
        let retried = await waitUntil { await recorder.count() == 2 }
        XCTAssertTrue(retried, "the retry must reach the handler")
        let retryPayload = await recorder.requests.last?.payload
        XCTAssertEqual(retryPayload, retryLine)

        // The abandoned first handler now returns: no second reply, and the
        // retry's state must survive.
        await lateGate.release()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(replies.count, 1, "a late completion must not write a reply")
        let handlerCalls = await recorder.count()
        XCTAssertEqual(handlerCalls, 2)

        await retryGate.release()
        let retryReplied = await waitUntil { HostFrames.all("HOSTREPLY", in: console.writtenText).count == 2 }
        XCTAssertTrue(retryReplied, "the retry's own reply must be written")
        let decodedReplies = HostFrames.all("HOSTREPLY", in: console.writtenText).compactMap { HostFrames.decoded($0.arguments) }
        XCTAssertEqual(decodedReplies.last, "status=ok action=list format=tgz entries=2 bytes=2 path=/workspace/retry.txt")
        let result = try await run.value
        XCTAssertEqual(result.exitCode, 0)
    }

    func testHostSideDeadlineCancelsWorkAndFailsExplicitly() async throws {
        let recorder = HostRequestRecorder()
        let claim = BridgeTokenClaim()
        let (console, channel) = makeChannel(limits: LinuxGuestLimits(hostRequestTimeout: 0.5)) { data in
            let text = String(decoding: data, as: UTF8.self)
            let frames = HostFrames.frames(text)
            if let hello = frames.first(where: { $0.name == "HELLO" }) {
                return [GuestFrames.caps(hello.token)]
            }
            if let exec = frames.first(where: { $0.name == "EXEC" }), claim.claim(exec.token) {
                return [GuestFrames.begin(exec.token), GuestFrames.hostRequest(
                    exec.token,
                    payload: HostFrames.encoded(HostFrames.requestLine(token: exec.token, action: "extract", format: "zip", source: "/workspace/a.zip", destination: "/workspace/out"))
                )]
            }
            if let reply = frames.first(where: { $0.name == "HOSTREPLY" }) {
                return [GuestFrames.end(reply.token, exit: 125)]
            }
            return []
        }
        await channel.installHostRequestHandler(
            LinuxGuestHostRequestHandler(helloArgument: helloArgument) { request, cancellation in
                await recorder.record(request)
                while !cancellation.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return "status=error code=cancelled detail=host request cancelled"
            }
        )
        let run = Task { try await channel.run(argv: ["floe-host", "archive", "extract", "/workspace/a.zip"], timeout: 10) }
        let replied = await waitUntil { HostFrames.all("HOSTREPLY", in: console.writtenText).count == 1 }
        XCTAssertTrue(replied, "the host deadline must answer instead of leaving the guest waiting")
        guard let reply = HostFrames.first("HOSTREPLY", in: console.writtenText),
              let decoded = HostFrames.decoded(reply.arguments) else {
            return XCTFail("no decodable reply")
        }
        XCTAssertTrue(decoded.hasPrefix("status=error code=host-timeout"), decoded)
        let result = try await run.value
        XCTAssertEqual(result.exitCode, 125)
    }

    // MARK: real runner wire bytes

    /// Captured verbatim from the real runner binary (`make -C
    /// FloeAgent/LinuxGuest/runner host`; source 07e5b0e5) with
    /// `Local/Scratch/e2-checks/capture_runner_hostreq.py`: HELLO with
    /// `archive=create,extract,list,decompress` → CAPS
    /// (`… hostArchive=create,extract,list,decompress`), then the inline EXEC
    /// for `floe-host archive list /workspace/a.tar.gz`. The runner answered
    /// the captured reply frame with `FLOE-END e2-raw-capture 0`, so the frame
    /// below is the real host-facing bytes, not a re-implementation.
    private static let realRunnerHostRequestFrame =
        "\u{1e}FLOE-HOSTREQ e2-raw-capture djEgdG9rZW49ZTItcmF3LWNhcHR1cmUgYWN0aW9uPWxpc3QgZm9ybWF0PXRneiBzb3VyY2U9L3dvcmtzcGFjZS9hLnRhci5neg==\u{1e}"

    func testRealRunnerHostRequestBytesParseAndDecodeStrictly() throws {
        let frames = HostFrames.frames(Self.realRunnerHostRequestFrame)
        let frame = try XCTUnwrap(frames.first)
        XCTAssertEqual(frame.name, "HOSTREQ")
        XCTAssertEqual(frame.token, "e2-raw-capture")
        XCTAssertEqual(
            LinuxGuestHostRequestCodec.decodePayload(frame.arguments),
            "v1 token=e2-raw-capture action=list format=tgz source=/workspace/a.tar.gz"
        )

        // Strict decode: a damaged frame is refused outright rather than
        // silently accepted with replacement bytes.
        let payload = frame.arguments
        XCTAssertNil(LinuxGuestHostRequestCodec.decodePayload(String(payload.dropLast())))
        XCTAssertNil(LinuxGuestHostRequestCodec.decodePayload(payload + "!"))
        XCTAssertNil(LinuxGuestHostRequestCodec.decodePayload("////"))
        XCTAssertNil(LinuxGuestHostRequestCodec.decodePayload(String(repeating: "A", count: 5000)))
        XCTAssertNil(LinuxGuestHostRequestCodec.decodePayload(""))
    }

    // MARK: registry wiring

    func testRegistryInstallsTheHandlerWithTheEnvironmentShareMap() async throws {
        let ledger = FakeSessionLedger()
        let factory = FakeSessionFactory(ledger: ledger) { _, token in
            token.hasPrefix("hello-") ? [GuestFrames.caps(token)] : [GuestFrames.begin(token), Data("ok".utf8), GuestFrames.end(token, exit: 0)]
        }
        let shareDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-host-bridge-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: shareDirectory, withIntermediateDirectories: true)
        let descriptor = LinuxGuestEnvironmentDescriptor(
            id: "env-bridge",
            ownerID: "owner",
            shares: [LinuxGuestShare(tag: LinuxGuestShare.workspaceTag, hostDirectory: shareDirectory)],
            imageID: "test-image"
        )
        let registry = TinyEMULinuxGuestRegistry(
            environments: FakeEnvironmentProvider(descriptors: ["env-bridge": descriptor]),
            images: FakeImageResolver(images: ["test-image": hostBridgeTestImage()]),
            limits: .standard,
            factory: factory
        )
        let spy = HostRequestHandlerSpy()
        registry.installHostRequestHandlerFactory { environmentID, pathMap in
            spy.record(environmentID: environmentID, pathMap: pathMap)
            return LinuxGuestHostRequestHandler(helloArgument: "archive=create,list") { _, _ in "status=ok" }
        }
        _ = try await registry.start(environmentID: "env-bridge", taskID: nil)
        _ = try await registry.run(
            environmentID: "env-bridge",
            argv: ["/bin/echo", "hi"],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 5,
            maxOutputBytes: 4096,
            cancellation: nil
        )
        XCTAssertEqual(spy.recordedEnvironmentID, "env-bridge")
        guard let pathMap = spy.recordedPathMap else { return XCTFail("the factory never saw a path map") }
        XCTAssertEqual(pathMap.guestPath(forHostPath: shareDirectory.appendingPathComponent("a.txt").path), "/workspace/a.txt")
        XCTAssertEqual(pathMap.hostPath(forGuestPath: "/workspace/a.txt")?.lastPathComponent, "a.txt")
        XCTAssertNil(pathMap.hostPath(forGuestPath: "/etc/passwd"))

        guard let console = ledger.console(for: "env-bridge") else { return XCTFail("no scripted console") }
        XCTAssertEqual(
            HostFrames.first("HELLO", in: String(decoding: console.written, as: UTF8.self))?.arguments,
            "archive=create,list"
        )
    }

    func testRegistryDoesNotAdvertiseWithoutAnInstalledFactory() async throws {
        let ledger = FakeSessionLedger()
        let factory = FakeSessionFactory(ledger: ledger) { _, token in
            token.hasPrefix("hello-") ? [GuestFrames.caps(token)] : [GuestFrames.begin(token), GuestFrames.end(token, exit: 0)]
        }
        let descriptor = LinuxGuestEnvironmentDescriptor(
            id: "env-plain",
            ownerID: "owner",
            shares: [LinuxGuestShare(tag: LinuxGuestShare.workspaceTag, hostDirectory: FileManager.default.temporaryDirectory)],
            imageID: "test-image"
        )
        let registry = TinyEMULinuxGuestRegistry(
            environments: FakeEnvironmentProvider(descriptors: ["env-plain": descriptor]),
            images: FakeImageResolver(images: ["test-image": hostBridgeTestImage()]),
            limits: .standard,
            factory: factory
        )
        _ = try await registry.start(environmentID: "env-plain", taskID: nil)
        _ = try await registry.run(
            environmentID: "env-plain",
            argv: ["/bin/echo", "hi"],
            workingDirectory: nil,
            standardInput: nil,
            timeout: 5,
            maxOutputBytes: 4096,
            cancellation: nil
        )
        guard let console = ledger.console(for: "env-plain") else { return XCTFail("no scripted console") }
        XCTAssertEqual(HostFrames.first("HELLO", in: String(decoding: console.written, as: UTF8.self))?.arguments, "")
    }
}

/// A qualified in-memory image for the registry-level tests (no image root:
/// the fake resolver never verifies digests).
func hostBridgeTestImage() -> LinuxGuestImage {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-host-bridge-image-\(UUID().uuidString)", isDirectory: true)
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
        qualificationEvidence: "host channel test \(UUID().uuidString)",
        qualificationRun: "run-host-channel",
        artifacts: artifacts
    )
}

// MARK: - Interactive session output integrity (terminal transport)

/// Regression host for the real-VM terminal stall fixed 2026-10-09. The
/// instrumented real run proved the guest had echoed and executed the whole
/// command — the engine, router and session buffer had delivered every byte
/// — while the visible terminal froze after an arbitrary partial line
/// (`printf 'FLOE_%s_READY\n' "$((6`): `nextOutput(timeoutMs:)` raced a
/// task-group timeout against `deliver`'s waiter resume and discarded the
/// winning chunk. These tests drive the real channel + session over a
/// scripted console; nothing below the session is stubbed. Payloads are
/// larger than the longest frame so no parser holdback is involved, and all
/// deadlines are generous enough for XCTest hop latency.
final class LinuxGuestInteractiveSessionOutputTests: XCTestCase {

    private func makeSession(
        _ apply: (ScriptedHostConsole, LinuxGuestInteractiveSession) async throws -> Void
    ) async throws {
        let console = ScriptedHostConsole { data in
            let text = String(decoding: data, as: UTF8.self)
            guard let hello = HostFrames.first("HELLO", in: text) else { return [] }
            return [GuestFrames.caps(hello.token)]
        }
        let channel = LinuxGuestCommandChannel(transport: console)
        let session = try await channel.openSession(
            sessionID: "race-session-token",
            argv: ["/bin/sh"],
            workingDirectory: nil,
            columns: 80,
            rows: 24
        )
        try await apply(console, session)
    }

    /// Every byte the guest sent must reach the reader, across hundreds of
    /// bounded reads whose timeouts interleave with deliveries while the
    /// executor is congested (the condition of the measured real-VM run).
    /// Pre-fix this loses chunks — deterministically enough under pressure
    /// that the real terminal froze on the first command after boot.
    func testSessionOutputIsNeverLostAcrossBoundedReadTimeouts() async throws {
        try await makeSession { console, session in
            // 64 bytes, larger than the longest frame: no parser holdback.
            let unit = String(repeating: "u", count: 63) + "\n"
            let fastChunks = 240
            let slowChunks = 60
            let unitBytes = unit.utf8.count
            let expectedBytes = (fastChunks + slowChunks) * unitBytes

            // Congest the cooperative pool like a booting app does: widens
            // the window in which a completed timeout used to swallow a
            // concurrently delivered chunk.
            let congestion = (0..<3).map { _ in
                Task {
                    for _ in 0..<120_000 { await Task.yield() }
                }
            }
            defer { congestion.forEach { $0.cancel() } }

            let consumer = Task {
                var collected = Data()
                let deadline = Date().addingTimeInterval(120)
                while collected.count < expectedBytes && Date() < deadline {
                    if let chunk = await session.nextOutput(timeoutMs: 40) {
                        collected.append(chunk)
                    }
                }
                return collected
            }
            let producer = Task {
                for i in 0..<fastChunks {
                    console.push([GuestFrames.out("race-session-token", unit)])
                    if i % 5 == 4 {
                        try? await Task.sleep(for: .milliseconds(7))
                    }
                }
                for _ in 0..<slowChunks {
                    try? await Task.sleep(for: .milliseconds(45))
                    console.push([GuestFrames.out("race-session-token", unit)])
                }
            }
            _ = await producer.result
            let collected = await consumer.value
            XCTAssertEqual(
                collected.count, expectedBytes,
                "session output lost bytes across bounded reads (got \(collected.count), want \(expectedBytes))"
            )
            XCTAssertEqual(
                String(decoding: collected, as: UTF8.self),
                String(repeating: unit, count: fastChunks + slowChunks),
                "session output content or order changed across bounded reads"
            )
        }
    }

    /// A timeout task scheduled by read A must never complete read B: A is
    /// satisfied quickly, then B waits long enough that A's stale timeout
    /// fires mid-wait, and B must still receive its chunk. Without the
    /// generation guard this truncated B to a spurious nil at A's deadline.
    func testStaleReadTimeoutCannotCompleteTheNextRead() async throws {
        try await makeSession { console, session in
            // A: long bounded read, satisfied well inside its own deadline.
            let readA = Task { await session.nextOutput(timeoutMs: 800) }
            try? await Task.sleep(for: .milliseconds(80))
            console.push([GuestFrames.out("race-session-token", String(repeating: "A", count: 64))])
            let gotA = await readA.value
            XCTAssertEqual(String(decoding: gotA ?? Data(), as: UTF8.self), String(repeating: "A", count: 64))

            // B installs its waiter before A's stale timeout fires (A's
            // deadline is ~700 ms out; the timeout task wakes mid-wait).
            let readB = Task { await session.nextOutput(timeoutMs: 4_000) }
            try? await Task.sleep(for: .milliseconds(900))
            console.push([GuestFrames.out("race-session-token", String(repeating: "B", count: 64))])
            let gotB = await readB.value
            XCTAssertEqual(
                String(decoding: gotB ?? Data(), as: UTF8.self), String(repeating: "B", count: 64),
                "the previous read's stale timeout truncated this read"
            )
            // Nothing phantom may be left for a later read.
            let tail = await session.nextOutput(timeoutMs: 100)
            XCTAssertNil(tail)
        }
    }

    /// Cancelling a read completes it promptly (never waits out its long
    /// bound) and must leave the next read fully functional — a late
    /// cancellation hop can never complete a later read's waiter, and bytes
    /// queued after the cancellation stay available to the next live read
    /// (an already-cancelled poll never consumes buffered bytes).
    func testCancelledReadReturnsPromptlyAndNeverCompletesTheNextRead() async throws {
        try await makeSession { console, session in
            let readA = Task { await session.nextOutput(timeoutMs: 30_000) }
            try? await Task.sleep(for: .milliseconds(80))
            let cancelStart = Date()
            readA.cancel()
            let gotA = await readA.value
            XCTAssertNil(gotA)
            XCTAssertLessThan(
                Date().timeIntervalSince(cancelStart), 5,
                "cancelled read was not completed promptly"
            )
            // The next read is unaffected by the cancelled read's teardown.
            let readB = Task { await session.nextOutput(timeoutMs: 4_000) }
            try? await Task.sleep(for: .milliseconds(150))
            console.push([GuestFrames.out("race-session-token", "after-cancel")])
            let gotB = await readB.value
            XCTAssertEqual(String(decoding: gotB ?? Data(), as: UTF8.self), "after-cancel")

            // An already-cancelled poll must not eat queued bytes.
            console.push([GuestFrames.out("race-session-token", "queued")])
            let cancelledPoll = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await session.nextOutput(timeoutMs: 4_000)
            }
            let gotCancelled = await cancelledPoll.value
            XCTAssertNil(gotCancelled, "an already-cancelled poll returned data")
            let readC = Task { await session.nextOutput(timeoutMs: 4_000) }
            let gotC = await readC.value
            XCTAssertEqual(
                String(decoding: gotC ?? Data(), as: UTF8.self), "queued",
                "bytes queued before an already-cancelled poll were consumed by it"
            )
        }
    }

    /// A hidden/unpolled terminal must not grow memory without bound. Past
    /// the 1 MB pending bound the session FAILS CLOSED with a structured,
    /// recoverable `failure` (displayed by the owner outside the terminal
    /// renderer): the unread bytes are cleared — a truncated tail cannot
    /// preserve decoder state — the guest receives CLOSE exactly once, and
    /// the existing reap path retires the channel-side registration. Other
    /// sessions on the same channel keep working. The pre-fix design
    /// duplicated every byte into an unconsumed unbounded stream alongside
    /// the unbounded pending buffer.
    func testUnpolledSessionOverflowFailsClosedRecoveredAndIsolated() async throws {
        let console = ScriptedHostConsole { data in
            let text = String(decoding: data, as: UTF8.self)
            guard let hello = HostFrames.first("HELLO", in: text) else { return [] }
            return [GuestFrames.caps(hello.token)]
        }
        let channel = LinuxGuestCommandChannel(transport: console)
        let overflowed = try await channel.openSession(
            sessionID: "overflow-session",
            argv: ["/bin/sh"],
            workingDirectory: nil,
            columns: 80,
            rows: 24
        )
        let other = try await channel.openSession(
            sessionID: "other-session",
            argv: ["/bin/sh"],
            workingDirectory: nil,
            columns: 80,
            rows: 24
        )
        // Push the overflowing session past the cap with nobody reading.
        let chunk = String(repeating: "y", count: LinuxGuestInteractiveSession.maxPendingOutputBytes + 1)
        console.push([GuestFrames.out("overflow-session", chunk)])
        // The session must fail closed promptly with a recoverable reason.
        let deadline = Date().addingTimeInterval(30)
        var finished = false
        while Date() < deadline {
            if await overflowed.isFinished { finished = true; break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(finished, "overflow did not fail the session closed")
        let failure = await overflowed.failure
        XCTAssertEqual(
            failure, LinuxGuestInteractiveSession.outputOverflowFailureCode,
            "overflow must carry the stable machine-readable failure code"
        )
        // Pending output was cleared: the reader sees a clean EOF, and the
        // session stays within the documented bound.
        let drained = await overflowed.nextOutput(timeoutMs: 100)
        XCTAssertNil(drained, "unread overflow bytes were retained")
        // CLOSE was sent to the guest exactly once.
        let closeFrames = console.writtenText.components(separatedBy: "\u{1e}FLOE-CLOSE overflow-session\u{1e}").count - 1
        XCTAssertEqual(closeFrames, 1, "guest CLOSE must be sent exactly once")
        // Another session on the same channel is unaffected: it still
        // streams output normally after the overflow.
        console.push([GuestFrames.out("other-session", "still-alive")])
        let otherRead = await other.nextOutput(timeoutMs: 4_000)
        XCTAssertEqual(String(decoding: otherRead ?? Data(), as: UTF8.self), "still-alive")
    }

    /// Single-character and small quiet bursts must be delivered promptly:
    /// the pre-fix parser held back every payload shorter than a marker
    /// until the NEXT burst, so the final bytes of a quiet shell sat
    /// invisible (the executed marker/prompt never reached the owner).
    func testSmallQuietBurstIsDeliveredPromptly() async throws {
        try await makeSession { console, session in
            console.push([GuestFrames.out("race-session-token", "x")])
            let one = await session.nextOutput(timeoutMs: 4_000)
            XCTAssertEqual(String(decoding: one ?? Data(), as: UTF8.self), "x")

            console.push([GuestFrames.out("race-session-token", "done\u{1b}[0m")])
            let two = await session.nextOutput(timeoutMs: 4_000)
            XCTAssertEqual(String(decoding: two ?? Data(), as: UTF8.self), "done\u{1b}[0m")
        }
    }
}

// MARK: - SessionParser framing contract

final class LinuxGuestSessionParserFramingTests: XCTestCase {
    private let token = "race-session-token"

    private func makeParser() -> LinuxGuestFraming.SessionParser {
        LinuxGuestFraming.SessionParser(sessionID: token)
    }

    /// A marker split across feeds must never be half-eaten as payload.
    func testSplitMarkerAcrossFeedsIsNotHalfEaten() {
        var parser = makeParser()
        let out = LinuxGuestFraming.sessionOutputMarker(token)
        // Feed the OUT marker one byte at a time.
        for byte in out {
            let progress = parser.feed(Data([byte]))
            XCTAssertEqual(progress, .needMore, "marker byte emitted as payload")
        }
        let payload = parser.feed(Data("hello".utf8))
        XCTAssertEqual(payload, .output(Data("hello".utf8)))
    }

    /// Payload is emitted immediately, keeping only a real marker-prefix
    /// suffix: no whole-marker-length holdback on quiet bursts.
    func testPayloadFlushesExceptActualMarkerPrefixSuffix() {
        var parser = makeParser()
        let out = LinuxGuestFraming.sessionOutputMarker(token)
        _ = parser.feed(out) // open the stream
        // Trailing ESC alone is a potential split marker and is held;
        // everything before it flushes now.
        let progress = parser.feed(Data("ab\u{1e}".utf8))
        XCTAssertEqual(progress, .output(Data("ab".utf8)))
        // The held ESC completes into a real marker and is stripped, not
        // delivered; the following bytes are payload.
        let rest = parser.feed(Data("FLOE-OUT \(token)\u{1e}ok".utf8))
        XCTAssertEqual(rest, .output(Data("ok".utf8)))
    }

    /// An END marker split across feeds terminates the session without
    /// losing payload that preceded the split.
    func testSplitEndMarkerStillTerminatesCleanly() {
        var parser = makeParser()
        let out = LinuxGuestFraming.sessionOutputMarker(token)
        let end = LinuxGuestFraming.sessionEndPrefix(token) // \x1eFLOE-END <token><space>
        let first = parser.feed(out + Data("tail\u{1e}FLOE-EN".utf8))
        XCTAssertEqual(first, .output(Data("tail".utf8)))
        let second = parser.feed(Data("D \(token) 0\u{1e}".utf8))
        XCTAssertEqual(second, .finished(0))
    }
}

// MARK: - Overflow failure surface (registry → center → owner)

/// The overflow failure must travel the real registry→backend→center chain
/// as structured data so the owner can show it outside the terminal
/// renderer; the pre-fix chain dropped it (readSession never surfaced
/// handle.failure and the result type could not carry it).
final class ShellSessionCenterFailureSurfaceTests: XCTestCase {

    private struct FakeBackend: LocalShellBackend {
        var exchangeResult: ShellExchangeResult
        var exchanged = false

        func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
            .failed(message: "not implemented")
        }

        func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
            ShellOpenResult(sessionID: "fake-session", initialOutput: "", alive: true)
        }

        func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
            exchangeResult
        }

        func closeSession(sessionID: String) async {}
    }

    func testExchangePassesRecoverableFailureThroughToOwnerResult() async throws {
        // Any structured failure string flows through; the known overflow
        // code maps to a localized owner presentation without the backend
        // embedding user-facing text.
        let reason = "output-overflow-detail-for-diagnostics"
        let backend = FakeBackend(exchangeResult: ShellExchangeResult(
            output: "",
            alive: false,
            terminalOutput: Data(),
            failure: reason,
            bytesRead: 0,
            bytesWritten: 0
        ))
        let center = ShellSessionCenter(backend: backend)
        let runID = UUID()
        let opened = try await center.open(
            command: "",
            cwd: ".",
            environment: [:],
            columns: 80,
            rows: 24,
            runID: runID,
            rootURL: FileManager.default.temporaryDirectory,
            cancellation: nil,
            forTerminal: true
        )
        let result = try await center.exchange(
            sessionID: opened.sessionID,
            input: nil,
            waitMs: 50,
            maxBytes: 64 * 1024,
            runID: runID,
            cancellation: nil,
            forTerminal: true
        )
        XCTAssertFalse(result.alive)
        XCTAssertEqual(result.failure, reason)
    }
}
