// SPDX-License-Identifier: MPL-2.0
//
// Author-written (NOT executed by this source stage) regression for the
// post112 FS01/FS12 owner/lease life cycle. The runtime generation proof used
// by the shell backend is a READ-ONLY `status` mailbox request: no lease,
// grant or foreground permit is attached, and the reply is parsed strictly so
// an absent/malformed token can never prove a generation change.
import XCTest
import FloeAndroidCore
import FloeAndroidShellTools

final class LinuxShellMailboxRuntimeStatusTests: XCTestCase {

    func testRuntimeStatusIsReadOnlyAndMapsMeasuredGeneration() async throws {
        let mailbox = LinuxShellMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 7))
        let transport = MailboxLinuxShellTransport(
            mailbox: mailbox,
            budgets: .init(statusMillis: 2_000))

        let statusTask = Task { try await transport.shellRuntimeStatus() }
        let claim = await Task.detached { mailbox.nextClaim(timeoutMillis: 2_000) }.value
        XCTAssertGreaterThan(claim, 0)
        XCTAssertFalse(mailbox.hasLiveTickets(runID: UUID()),
                       "the read-only status ticket is not a run-scoped shell.start claim")

        var operation = [CChar](repeating: 0, count: 128)
        let described = operation.withUnsafeMutableBufferPointer {
            mailbox.describe(claim: claim, buffer: $0.baseAddress, capacity: Int32($0.count))
        }
        XCTAssertGreaterThan(described, 0)
        let operationText = String(decoding: operation.prefix(Int(described)).map {
            UInt8(bitPattern: $0)
        }, as: UTF8.self)
        XCTAssertEqual(#"{"operation":"status"}"#, operationText)

        let json = #"{"runtimePid":4242,"runtimeBootToken":"boot-2","active":true,"runtimeRecoveryProven":true}"#
        var bytes = Array(json.utf8)
        let completed = bytes.withUnsafeBufferPointer {
            mailbox.complete(claim: claim, status: 0,
                             value: $0.baseAddress, valueLen: Int32(bytes.count))
        }
        XCTAssertEqual(0, completed)

        let status = try await statusTask.value
        XCTAssertEqual(4242, status.runtimePid ?? -1)
        XCTAssertEqual("boot-2", status.runtimeBootToken ?? "")
        XCTAssertEqual(true, status.active ?? false)
        XCTAssertEqual(true, status.runtimeRecoveryProven ?? false)
        XCTAssertFalse(mailbox.hasLiveTickets)
    }

    func testMalformedRuntimeGenerationFailsClosed() async throws {
        let mailbox = LinuxShellMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 8))
        let transport = MailboxLinuxShellTransport(
            mailbox: mailbox,
            budgets: .init(statusMillis: 2_000))

        let statusTask = Task { try await transport.shellRuntimeStatus() }
        let claim = await Task.detached { mailbox.nextClaim(timeoutMillis: 2_000) }.value
        XCTAssertGreaterThan(claim, 0)
        let json = #"{"runtimePid":1,"runtimeBootToken":"bad token","active":true,"runtimeRecoveryProven":true}"#
        var bytes = Array(json.utf8)
        let completed = bytes.withUnsafeBufferPointer {
            mailbox.complete(claim: claim, status: 0,
                             value: $0.baseAddress, valueLen: Int32(bytes.count))
        }
        XCTAssertEqual(0, completed)

        do {
            _ = try await statusTask.value
            XCTFail("a malformed boot token must never prove a generation change")
        } catch let error as LinuxShellTransportError {
            XCTAssertEqual(LinuxShellTransportError.replyMalformed, error)
        }
    }
}
