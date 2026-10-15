// FloeExecutionTests — duplicate routing-token fail-closed on the REAL guest
// command channel.
//
// `LinuxGuestCommandChannel.registerToken` used to overwrite
// `tokenStreams[token]` silently: if any caller ever presented a token that
// was already active (two clients reusing one caller-side identity), the new
// stream replaced the original and the original client's frames — output,
// END/FAILED completion and control — were rerouted to the duplicate (the
// PTY-hijack class bug). These regressions drive the production channel over
// the scripted console and prove:
//
//  * a duplicate active token is refused (typed `invalidConfiguration`)
//    BEFORE the map is mutated: the original stays the sole owner, keeps
//    receiving its own frames and completes with its real END;
//  * the refused duplicate did not unregister the original (live token count
//    stays 1 while the original owns the token);
//  * an in-flight production command (`run`, whose token the channel minted)
//    cannot be replaced mid-flight by a duplicate registration and still
//    completes with its own output.

import Foundation
import XCTest
import FloeCore
@testable import FloeExecution

/// Scripted console reply for the HELLO probe (same wire shape the backend
/// tests use; kept local because their helpers are file-private).
private func duplicateTokenCaps(_ token: String) -> [Data] {
    [Data("\u{1e}FLOE-CAPS \(token) runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4\u{1e}\u{1e}FLOE-END \(token) 0\u{1e}".utf8)]
}

/// Lock-backed accumulator for the bounded stream read below.
private final class TokenStreamDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var snapshot: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Reads a token stream until `terminal` matches the accumulated bytes or the
/// deadline expires (nil). The reader task is cancelled on timeout and never
/// awaited past the bound, so a routing regression fails the test instead of
/// hanging the suite.
private func boundedCollect(
    _ stream: LinuxGuestTokenStream,
    timeout: TimeInterval = 3,
    terminal: @Sendable (Data) -> Bool
) async -> Data? {
    let box = TokenStreamDataBox()
    let reader = Task {
        while let chunk = await stream.nextCancellable() {
            box.append(chunk)
        }
    }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if terminal(box.snapshot) {
            reader.cancel()
            return box.snapshot
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    reader.cancel()
    return nil
}

final class LinuxGuestDuplicateTokenTests: XCTestCase {
    /// A duplicate registration is refused while the original keeps its own
    /// routing: the original stream receives exactly its frames and completes.
    func testDuplicateTokenFailsClosedAndOriginalKeepsRoutingItsFrames() async throws {
        let console = TestLinuxGuestConsole()
        console.setHandler { token in token.hasPrefix("hello-") ? duplicateTokenCaps(token) : [] }
        let channel = LinuxGuestCommandChannel(transport: console)
        _ = try await channel.probeCapabilities(timeout: 2)

        let original = LinuxGuestTokenStream()
        try await channel.registerToken("dup-token-1", stream: original)
        let duplicate = LinuxGuestTokenStream()
        do {
            try await channel.registerToken("dup-token-1", stream: duplicate)
            XCTFail("a duplicate active token must be refused")
        } catch let error as LinuxGuestError {
            guard case .invalidConfiguration(let detail) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(detail.contains("already active"), "got: \(detail)")
        }
        let liveTokens = await channel.liveTokenCount
        XCTAssertEqual(liveTokens, 1, "the duplicate must not be installed")

        // The original still owns the token: its frames arrive and complete.
        console.push([Data("\u{1e}FLOE-BEGIN dup-token-1\u{1e}\u{1e}FLOE-OUT dup-token-1\u{1e}owner-frame\u{1e}FLOE-END dup-token-1 0\u{1e}".utf8)])
        let collected = await boundedCollect(original) { data in
            String(decoding: data, as: UTF8.self).contains("\u{1e}FLOE-END dup-token-1 0\u{1e}")
        }
        let text = String(decoding: try XCTUnwrap(collected, "the original stream never received its END frame"), as: UTF8.self)
        XCTAssertTrue(text.contains("owner-frame"), "the original received its own payload: \(text)")
        XCTAssertTrue(text.hasPrefix("\u{1e}FLOE-BEGIN dup-token-1\u{1e}"), "frames stay in order for the original")
    }

    /// The production command path keeps its token while a duplicate
    /// registration is attempted mid-flight; the command completes with its
    /// own output and exit code.
    func testInFlightCommandTokenCannotBeReplacedByDuplicateRegistration() async throws {
        let console = TestLinuxGuestConsole()
        console.setHandler { token in token.hasPrefix("hello-") ? duplicateTokenCaps(token) : [] }
        let channel = LinuxGuestCommandChannel(transport: console)
        let runTask = Task { try await channel.run(argv: ["/bin/sh", "-c", "echo call_1"], timeout: 5) }

        // The EXEC frame is written only after the run reserved its token, so
        // observing it proves the original owns the token right now.
        let deadline = Date().addingTimeInterval(5)
        var tokens: [String] = []
        while Date() < deadline {
            tokens = TestLinuxGuestConsole.tokens(in: console.written, name: "EXEC")
            if !tokens.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let token = try XCTUnwrap(tokens.first, "the in-flight command never reached the guest")

        let duplicate = LinuxGuestTokenStream()
        do {
            try await channel.registerToken(token, stream: duplicate)
            XCTFail("the in-flight command's token must not be replaceable")
        } catch let error as LinuxGuestError {
            guard case .invalidConfiguration = error else {
                return XCTFail("unexpected error \(error)")
            }
        }

        // Only the original owner's frames complete the command.
        console.push([Data("\u{1e}FLOE-BEGIN \(token)\u{1e}\u{1e}FLOE-OUT \(token)\u{1e}owner-output\u{1e}FLOE-END \(token) 0\u{1e}".utf8)])
        let result = try await runTask.value
        XCTAssertEqual(result.stdout, "owner-output")
        XCTAssertEqual(result.exitCode, 0)
    }
}
