// SPDX-License-Identifier: MPL-2.0
//
// Authored-only focused suite: the mailbox settles a failed START with the
// OPTIONAL strict typed reverse-restore evidence WITHOUT poisoning the
// legacy failed terminal (job-150dee8e1ed14ba1). The "host" below is the
// SAME Swift mailbox API the trusted Kotlin pump drives over JNI
// (claim -> describe -> takePayload -> exchange -> complete); nothing here
// crosses Binder or touches a device. NOT executed by the authoring job;
// Main compiles it with the existing FloeAndroidShellToolsTests cohort.
import XCTest
import Foundation
import FloeCore
@testable import FloeAndroidCore
import FloeAndroidShellTools

final class LinuxShellMailboxFailedStartSettleTests: XCTestCase {

    private let key = String(repeating: "ab", count: 16)
    private let run = "A1B2C3D4-0000-4000-9000-000000000004"

    private func recoveryJSON(record: String = "importRestore",
                              sessionKey: String? = nil,
                              runText: String? = nil,
                              trigger: String = "t",
                              restored: String = "3",
                              reverted: String = "1",
                              retained: String = "0",
                              extra: String = "") -> String {
        "{\"record\":\"\(record)\",\"sessionKey\":\"\(sessionKey ?? key)\","
            + "\"runID\":\"\(runText ?? run)\",\"trigger\":\"\(trigger)\","
            + "\"restoredPriorChanges\":\(restored),\"revertedNewEntries\":\(reverted),"
            + "\"retainedFailures\":\(retained)\(extra)}"
    }

    private func frame(code: String = "runtime_start_stopped",
                       failureCode: String? = nil,
                       recovery: String? = nil) -> String {
        var parts = ["\"code\":\"\(code)\""]
        if let failureCode { parts.append("\"failureCode\":\"\(failureCode)\"") }
        if let recovery { parts.append("\"recovery\":\(recovery)") }
        return "{" + parts.joined(separator: ",") + "}"
    }

    private func makeMailbox() -> (LinuxShellMailbox, MailboxLinuxShellTransport) {
        let mailbox = LinuxShellMailbox(sleeper: { nanoseconds in
            try? await Task.sleep(nanoseconds: min(nanoseconds, 1_000_000))
        })
        let budgets = MailboxLinuxShellTransport.Budgets(startMillis: 2_000)
        return (mailbox, MailboxLinuxShellTransport(mailbox: mailbox, budgets: budgets))
    }

    private func startRequest() -> LinuxShellStartRequest {
        LinuxShellStartRequest(projectID: UUID(), runID: UUID(uuidString: run)!, conversationID: UUID(),
                               environmentID: "linux.local", command: "echo hi", cwd: ".",
                               environment: [:], rows: 24, columns: 80, timeoutSeconds: 5)
    }

    /// Claim + drain the shell.start ticket on the "host" side.
    private func claimStart(_ mailbox: LinuxShellMailbox) throws -> Int64 {
        let claim = mailbox.nextClaim(timeoutMillis: 2_000)
        XCTAssertGreaterThan(claim, 0)
        var buffer = [CChar](repeating: 0, count: 128)
        let written = mailbox.describe(claim: claim, buffer: &buffer, capacity: 128)
        XCTAssertGreaterThan(written, 0)
        let length = max(0, mailbox.payloadLength(claim: claim))
        var payloadBuffer = [UInt8](repeating: 0, count: Int(length))
        if length > 0 {
            XCTAssertEqual(mailbox.takePayload(claim: claim, buffer: &payloadBuffer, capacity: length), length)
        }
        return claim
    }

    private func settle(_ mailbox: LinuxShellMailbox, claim: Int64, json: String) -> Int32 {
        var buffer = Data(json.utf8)
        return buffer.withUnsafeBytes { raw in
            mailbox.complete(claim: claim, status: 1,
                             value: raw.bindMemory(to: UInt8.self).baseAddress!,
                             valueLen: Int32(buffer.count))
        }
    }

    // MARK: - Legacy terminal stays byte-identical

    func testLegacyFailedStartFrameUnchanged() async throws {
        let (mailbox, transport) = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 90))
        let request = startRequest()
        let replyTask = Task { try await transport.shellStart(request) }
        let claim = try claimStart(mailbox)
        XCTAssertEqual(settle(mailbox, claim: claim, json: frame()), 0)
        do {
            _ = try await replyTask.value
            XCTFail("expected remoteFailed")
        } catch let error as LinuxShellTransportError {
            XCTAssertEqual(error, .remoteFailed(code: "runtime_start_stopped"))
        }
    }

    // MARK: - Typed handoff: a strictly well-formed pair becomes the evidence case

    func testWellFormedFailedStartEvidenceDeliversTypedCase() async throws {
        let (mailbox, transport) = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 91))
        let request = startRequest()
        let replyTask = Task { try await transport.shellStart(request) }
        let claim = try claimStart(mailbox)
        let json = frame(code: "runtime_start_interrupted",
                         failureCode: "importCancelled",
                         recovery: recoveryJSON(trigger: "cancelRequested", restored: "3",
                                                reverted: "1", retained: "0"))
        XCTAssertEqual(settle(mailbox, claim: claim, json: json), 0)
        do {
            _ = try await replyTask.value
            XCTFail("expected typed failed-start evidence")
        } catch let error as LinuxShellTransportError {
            XCTAssertEqual(error, .remoteFailedWithRestore(
                code: "runtime_start_interrupted",
                restore: LinuxShellImportRestore(
                    failureCode: "importCancelled", sessionKey: key, runID: run,
                    trigger: "cancelRequested", restoredPriorChanges: 3,
                    revertedNewEntries: 1, retainedFailures: 0)))
        }
    }

    // MARK: - Malformed evidence NEVER poisons the settled legacy terminal

    func testMalformedEvidenceStillSettlesLegacyByteIdentical() async throws {
        let malformedFrames = [
            // missing failureCode half
            frame(recovery: recoveryJSON()),
            // missing recovery half
            frame(failureCode: "importCancelled"),
            // wrong record token
            frame(failureCode: "importCancelled", recovery: recoveryJSON(record: "exportFinish")),
            // Bool counter coerced to a number
            frame(failureCode: "importCancelled", recovery: recoveryJSON(restored: "true")),
            // fractional counter (never rounded)
            frame(failureCode: "importCancelled", recovery: recoveryJSON(restored: "3.5")),
            // negative counter
            frame(failureCode: "importCancelled", recovery: recoveryJSON(restored: "-1")),
            // foreign extra field (closed names)
            frame(failureCode: "importCancelled",
                  recovery: recoveryJSON(extra: ",\"absPath\":\"/tmp/x\"")),
            // uppercase-hex session key grammar break
            frame(failureCode: "importCancelled", recovery: recoveryJSON(sessionKey: key.uppercased())),
            // non-canonical run echo
            frame(failureCode: "importCancelled", recovery: recoveryJSON(runText: "not-a-uuid")),
            // Well-formed but foreign run must never attach to this ticket.
            frame(failureCode: "importCancelled",
                  recovery: recoveryJSON(runText: "B1B2C3D4-0000-4000-9000-000000000004")),
            // overlong failureCode token
            frame(failureCode: String(repeating: "c", count: 49), recovery: recoveryJSON()),
        ]
        for (index, json) in malformedFrames.enumerated() {
            let (mailbox, transport) = makeMailbox()
            XCTAssertTrue(mailbox.bind(epoch: UInt64(100 + index)))
            let request = startRequest()
        let replyTask = Task { try await transport.shellStart(request) }
            let claim = try claimStart(mailbox)
            // Settlement itself SUCCEEDS (0): the supplementary object can
            // never reject or poison the legacy failed terminal.
            XCTAssertEqual(settle(mailbox, claim: claim, json: json), 0, "frame \(index) must still settle")
            do {
                _ = try await replyTask.value
                XCTFail("frame \(index): expected legacy remoteFailed")
            } catch let error as LinuxShellTransportError {
                XCTAssertEqual(error, .remoteFailed(code: "runtime_start_stopped"),
                               "frame \(index) must deliver the unchanged legacy code")
            }
        }
    }

    func testEvidenceFrameWithAbsentCodeKeepsDefaultCode() async throws {
        // The existing default-code behaviour stays: a frame without "code"
        // still settles with "operation_failed"; the strictly valid typed
        // half binds to that same default skeleton.
        let (mailbox, transport) = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 120))
        let request = startRequest()
        let replyTask = Task { try await transport.shellStart(request) }
        let claim = try claimStart(mailbox)
        let recovery = recoveryJSON(trigger: "cancelRequested")
        let json = "{\"failureCode\":\"importCancelled\",\"recovery\":\(recovery)}"
        XCTAssertEqual(settle(mailbox, claim: claim, json: json), 0)
        do {
            _ = try await replyTask.value
            XCTFail("expected typed evidence with the default legacy code")
        } catch let error as LinuxShellTransportError {
            XCTAssertEqual(error, .remoteFailedWithRestore(
                code: "operation_failed",
                restore: LinuxShellImportRestore(
                    failureCode: "importCancelled", sessionKey: key, runID: run,
                    trigger: "cancelRequested", restoredPriorChanges: 3,
                    revertedNewEntries: 1, retainedFailures: 0)))
        }
    }
}
