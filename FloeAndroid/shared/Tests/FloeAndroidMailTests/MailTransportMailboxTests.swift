// SPDX-License-Identifier: MPL-2.0
//
// C06 transport mailbox tests. Authored source; NOT RUN by the source lane.
// A simulated App lane settles the native tickets; no socket, TLS, device or
// credential participates.

import Foundation
import Testing
import FloeCore
@testable import FloeAndroidMail

private final class SimulatedLane: @unchecked Sendable {
    private let mailbox: MailTransportMailbox
    private let epoch: UInt64
    private let readPayload: Data
    private let completeReads: Bool
    private var task: Task<Void, Never>?

    init(
        mailbox: MailTransportMailbox,
        epoch: UInt64,
        readPayload: Data = Data("hello".utf8),
        completeReads: Bool = true
    ) {
        self.mailbox = mailbox
        self.epoch = epoch
        self.readPayload = readPayload
        self.completeReads = completeReads
    }

    func start() {
        task = Task.detached { [self] in
            while true {
                let claim = mailbox.nextClaim(timeout: 0.05)
                if claim == -1 {
                    _ = mailbox.laneClosed(epoch: epoch)
                    return
                }
                if claim == 0 { continue }
                guard let text = mailbox.describe(claim: claim),
                      let data = text.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let operation = object["op"] as? String else {
                    _ = mailbox.complete(claim: claim, status: MailTransportStatus.protocolViolation, data: Data())
                    continue
                }
                if operation == "read" {
                    if completeReads {
                        _ = mailbox.complete(
                            claim: claim,
                            status: MailTransportStatus.ok,
                            data: readPayload
                        )
                    }
                    // else: deliberately leave the claim pending to exercise
                    // cancellation; closeAll will fence it.
                } else {
                    _ = mailbox.complete(
                        claim: claim,
                        status: MailTransportStatus.ok,
                        data: Data()
                    )
                }
            }
        }
    }

    func stop() {
        _ = mailbox.closeAll(timeout: 3)
        task?.cancel()
    }
}

@Suite("FloeAndroidMail transport mailbox")
struct MailTransportMailboxTests {
    private let deadline = Date().addingTimeInterval(30)

    @Test("Bind/open/write/read/close round-trip settles exactly once")
    func roundTrip() async throws {
        let mailbox = MailTransportMailbox()
        let lane = SimulatedLane(mailbox: mailbox, epoch: 7)
        #expect(mailbox.bind(epoch: 7) == MailTransportStatus.ok)
        #expect(mailbox.laneReady(epoch: 7) == MailTransportStatus.ok)
        lane.start()
        defer { lane.stop() }

        let session = try mailbox.open(
            host: "127.0.0.1",
            port: 993,
            tls: .implicitTLS,
            deadline: deadline,
            cancelled: { false }
        )
        try mailbox.write(
            session: session,
            data: Data("NOOP\r\n".utf8),
            deadline: deadline,
            cancelled: { false }
        )
        let read = try mailbox.readSome(
            session: session,
            maximumBytes: 128,
            deadline: deadline,
            cancelled: { false }
        )
        #expect(read == Data("hello".utf8))
        #expect(mailbox.close(session: session, timeout: 2))
    }

    @Test("A stale or duplicate settle is rejected, not resumed")
    func duplicateSettleRejected() {
        let mailbox = MailTransportMailbox()
        #expect(mailbox.complete(
            claim: 999,
            status: MailTransportStatus.ok,
            data: Data()
        ) == -1)
    }

    @Test("An unbound mailbox never opens a plaintext session")
    func unboundRefused() {
        let mailbox = MailTransportMailbox()
        #expect(throws: MailFailure.transportUnavailable) {
            try mailbox.open(
                host: "127.0.0.1",
                port: 143,
                tls: .startTLS,
                deadline: deadline,
                cancelled: { false }
            )
        }
    }

    @Test("Bind fences a second epoch until root stop closes the first")
    func epochFencing() {
        let mailbox = MailTransportMailbox()
        #expect(mailbox.bind(epoch: 8) == MailTransportStatus.ok)
        #expect(mailbox.bind(epoch: 9) == MailTransportStatus.busy)
        #expect(mailbox.closeAll(timeout: 1))
        #expect(mailbox.bind(epoch: 9) == MailTransportStatus.ok)
    }

    @Test("Cancellation wakes a blocked read without claiming socket success")
    func cancellationWakesReader() async throws {
        let mailbox = MailTransportMailbox()
        let lane = SimulatedLane(mailbox: mailbox, epoch: 10, completeReads: false)
        #expect(mailbox.bind(epoch: 10) == MailTransportStatus.ok)
        #expect(mailbox.laneReady(epoch: 10) == MailTransportStatus.ok)
        lane.start()
        defer { lane.stop() }
        let session = try mailbox.open(
            host: "127.0.0.1",
            port: 143,
            tls: .startTLS,
            deadline: deadline,
            cancelled: { false }
        )
        let flag = MailCancelledFlag.Box()
        let task = Task {
            try mailbox.readSome(
                session: session,
                maximumBytes: 64,
                deadline: Date().addingTimeInterval(5),
                cancelled: { flag.isCancelled }
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        flag.cancel()
        await #expect(throws: MailFailure.cancelled) {
            try await task.value
        }
        _ = mailbox.close(session: session, timeout: 2)
    }

    @Test("Root stop reports drained only after the lane acknowledges")
    func closeAllNeedsLaneAck() async throws {
        let mailbox = MailTransportMailbox()
        let lane = SimulatedLane(mailbox: mailbox, epoch: 11)
        #expect(mailbox.bind(epoch: 11) == MailTransportStatus.ok)
        #expect(mailbox.laneReady(epoch: 11) == MailTransportStatus.ok)
        lane.start()
        defer { lane.stop() }
        _ = try mailbox.open(
            host: "127.0.0.1",
            port: 993,
            tls: .implicitTLS,
            deadline: deadline,
            cancelled: { false }
        )
        #expect(mailbox.closeAll(timeout: 3))
    }
}
