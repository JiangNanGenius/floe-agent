// SPDX-License-Identifier: MPL-2.0
//
// C06 no-replay journal tests. Authored source; NOT RUN by the source lane.

import Foundation
import Testing
import FloeCore
@testable import FloeAndroidMail

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-c06-journal-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func digest(_ value: String) -> String {
    FloeDigest.sha256Hex(Data(value.utf8))
}

@Suite("FloeAndroidMail delivery journal")
struct MailDeliveryJournalTests {
    @Test("Reserve precedes send and a replay never resends")
    func reserveReplayFinish() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MailDeliveryJournal(directory: directory)
        let request = UUID()
        let first = try journal.reserve(requestID: request, digest: digest("m1"))
        #expect(first == nil)
        let replay = try journal.reserve(requestID: request, digest: digest("m1"))
        #expect(replay == .deliveryUnknown)
        try journal.finish(requestID: request, digest: digest("m1"), state: .acceptedByServer)
        let accepted = try journal.reserve(requestID: request, digest: digest("m1"))
        #expect(accepted == .acceptedByServer)
        #expect(throws: MailFailure.invalidMessage) {
            try journal.reserve(requestID: request, digest: digest("different"))
        }
    }

    @Test("Not-submitted is a terminal replay, not a success")
    func notSubmittedReplay() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MailDeliveryJournal(directory: directory)
        let request = UUID()
        let first = try journal.reserve(requestID: request, digest: digest("m2"))
        #expect(first == nil)
        try journal.finish(requestID: request, digest: digest("m2"), state: .notSubmitted)
        let replay = try journal.reserve(requestID: request, digest: digest("m2"))
        #expect(replay == .notSubmitted)
    }

    @Test("Corrupt receipt fails closed and is preserved")
    func corruptReceipt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = UUID()
        try Data("not-json".utf8).write(
            to: directory.appendingPathComponent(request.uuidString + ".json")
        )
        let journal = MailDeliveryJournal(directory: directory)
        #expect(throws: MailFailure.invalidMessage) {
            try journal.reserve(requestID: request, digest: digest("m3"))
        }
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(request.uuidString + ".json").path
        ))
    }
}

@Suite("FloeAndroidMail mutation journal")
struct MailMutationJournalTests {
    private func provenance(account: UUID = UUID(), uid: String = "9") -> MailMutationJournal.Provenance {
        MailMutationJournal.Provenance(
            accountID: account,
            action: "move",
            sourceFolder: "INBOX",
            destination: "Archive",
            uid: uid,
            mailboxVersion: "100",
            messageID: "<id@example>",
            byteCount: 123
        )
    }

    @Test("Reservation, provenance and terminal replay")
    func reserveFinishReplay() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MailMutationJournal(directory: directory)
        let request = UUID()
        let facts = provenance()
        let first = try journal.reserve(
            requestID: request, digest: digest("m"), provenance: facts
        )
        #expect(first == nil)
        let snapshot = try #require(journal.snapshot(requestID: request, digest: digest("m")))
        #expect(snapshot.state == .mutationUnknown)
        #expect(snapshot.provenance == facts)
        try journal.finish(requestID: request, digest: digest("m"), state: .completed)
        let replay = try journal.reserve(requestID: request, digest: digest("m"))
        #expect(replay == .completed)
        #expect(throws: MailFailure.invalidMessage) {
            try journal.clear(requestID: request, digest: digest("m"))
        }
    }

    @Test("A notStarted receipt can be cleared only after proof")
    func clearOnlyNotStarted() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MailMutationJournal(directory: directory)
        let request = UUID()
        let first = try journal.reserve(requestID: request, digest: digest("n"))
        #expect(first == nil)
        try journal.finish(requestID: request, digest: digest("n"), state: .notStarted)
        try journal.clear(requestID: request, digest: digest("n"))
        let cleared = try journal.snapshot(requestID: request, digest: digest("n"))
        #expect(cleared == nil)
    }

    @Test("Owner lock is exclusive and released explicitly")
    func ownerLockExclusion() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MailMutationJournal(directory: directory)
        let request = UUID()
        guard case .acquired(let first) = journal.acquireOwnerLockResult(requestID: request) else {
            Issue.record("expected the first owner lock")
            return
        }
        guard case .activeOther = journal.acquireOwnerLockResult(requestID: request) else {
            first.release()
            Issue.record("expected activeOther for the second lock")
            return
        }
        first.release()
        guard case .acquired(let second) = journal.acquireOwnerLockResult(requestID: request) else {
            Issue.record("expected reacquisition after release")
            return
        }
        second.release()
    }

    @Test("Orchestration grants one attempt, then replays the receipt")
    func orchestrationFirstAttemptThenReplay() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MailMutationJournal(directory: directory)
        let requestID = UUID()
        let accountID = UUID()
        let operation = MailMoveOperation(
            requestID: requestID,
            accountID: accountID,
            action: "move",
            sourceFolder: "INBOX",
            destination: "Archive",
            uid: "9",
            mailboxVersion: "100"
        )
        let orchestration = MailMoveOrchestration(
            journal: journal,
            seams: .init(
                identity: { _ in
                    MailMutationJournal.StableIdentity(messageID: "<id@example>", byteCount: 123)
                },
                reconcile: { _ in
                    .ambiguous(reason: "test")
                }
            )
        )
        switch try await orchestration.execute(operation) {
        case .firstAttempt(let attempt):
            try journal.finish(
                requestID: attempt.requestID,
                digest: attempt.digest,
                state: .completed
            )
            attempt.release()
        default:
            Issue.record("expected firstAttempt")
        }
        switch try await orchestration.execute(operation) {
        case .replay(let state):
            #expect(state == .completed)
        default:
            Issue.record("expected completed replay")
        }
    }

    @Test("An unconfirmed outcome is reconciled read-only and never repeated")
    func orchestrationReconcilesUnknown() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MailMutationJournal(directory: directory)
        let requestID = UUID()
        let facts = provenance(uid: "10")
        let operation = MailMoveOperation(
            requestID: requestID,
            accountID: facts.accountID,
            action: facts.action,
            sourceFolder: facts.sourceFolder,
            destination: facts.destination,
            uid: facts.uid,
            mailboxVersion: facts.mailboxVersion
        )
        let reserved = try journal.reserve(
            requestID: requestID,
            digest: operation.digest,
            provenance: facts
        )
        #expect(reserved == nil)
        let orchestration = MailMoveOrchestration(
            journal: journal,
            seams: .init(
                identity: { _ in
                    Issue.record("identity must not run for an existing receipt")
                    return .init(messageID: nil, byteCount: 0)
                },
                reconcile: { _ in .ambiguous(reason: "insufficientEvidence") }
            )
        )
        switch try await orchestration.execute(operation) {
        case .uncertain(let reason):
            #expect(reason == "insufficientEvidence")
        default:
            Issue.record("expected uncertain")
        }
        let replay = try journal.reserve(requestID: requestID, digest: operation.digest)
        #expect(replay == .mutationUnknown)
    }
}
