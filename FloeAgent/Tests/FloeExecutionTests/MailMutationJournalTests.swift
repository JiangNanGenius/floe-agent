// FloeExecutionTests — mailbox receipt recovery and the non-preemptible
// single-owner contract for mail mutations (move/archive/trash).
//
// These tests drive the SAME orchestration type MailTools runs; the IMAP
// layer is replaced by injected seams so every ordering (including the
// concurrent same-request races) is deterministic. No mail account, network,
// send, move or delete is involved.

import Foundation
import Testing
@testable import FloeExecution

/// Simulates a read-only receipt store. Kept as a free function so
/// `@Sendable` seam hooks can call it without capturing the test suite.
private func setMailTestPermissions(_ permissions: Int, of directory: URL) throws {
    try FileManager.default.setAttributes(
        [.posixPermissions: permissions],
        ofItemAtPath: directory.path
    )
}

@Suite("Mail mutation receipts and ownership")
struct MailMutationJournalTests {
    private let accountID = UUID()

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-mail-mutation-\(UUID().uuidString)", isDirectory: true)
    }

    private func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private func operation(
        requestID: UUID = UUID(),
        action: String = "move",
        folder: String = "INBOX",
        uid: String = "42",
        destination: String = "Archive"
    ) -> MailMoveOperation {
        MailMoveOperation(
            requestID: requestID,
            accountID: accountID,
            action: action,
            sourceFolder: folder,
            destination: destination,
            uid: uid,
            mailboxVersion: "777"
        )
    }

    private func reservation(_ op: MailMoveOperation) -> MailMutationJournal.Provenance {
        MailMutationJournal.Provenance(
            accountID: op.accountID,
            action: op.action,
            sourceFolder: op.sourceFolder,
            destination: op.destination,
            uid: op.uid,
            mailboxVersion: op.mailboxVersion,
            messageID: "<stable@example.test>",
            byteCount: 2048
        )
    }

    /// Deterministic doubles for the read-only source identity and the
    /// read-only reconciliation. Hooks run inside the seam so a test can
    /// simulate a concurrent execution at an exact point in the sequence.
    private final class Exchange: @unchecked Sendable {
        private let lock = NSLock()
        private var _identityCalls = 0
        private var _reconcileCalls = 0
        private var _identityResult: Result<MailMutationJournal.StableIdentity, MailFailure> =
            .success(MailMutationJournal.StableIdentity(messageID: "<stable@example.test>", byteCount: 2048))
        private var _reconcileResult: Result<MailMutationJournal.Reconciliation, MailFailure> =
            .success(.ambiguous(reason: "not configured"))
        var identityHook: (@Sendable () throws -> Void)?
        /// Runs inside the reconcile seam, after the verdict is fixed and
        /// before the orchestration can write the receipt back.
        var reconcileHook: (@Sendable () throws -> Void)?

        var identityCalls: Int { locked { _identityCalls } }
        var reconcileCalls: Int { locked { _reconcileCalls } }

        func setIdentity(_ result: Result<MailMutationJournal.StableIdentity, MailFailure>) {
            locked { _identityResult = result }
        }

        func setReconcile(_ result: Result<MailMutationJournal.Reconciliation, MailFailure>) {
            locked { _reconcileResult = result }
        }

        /// NSLock is not callable from async contexts under Swift 6, so every
        /// locked section is a plain synchronous helper.
        private func locked<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body()
        }

        private func performIdentityCall() throws -> Result<MailMutationJournal.StableIdentity, MailFailure> {
            lock.lock(); defer { lock.unlock() }
            _identityCalls += 1
            try identityHook?()
            return _identityResult
        }

        private func performReconcileCall() throws -> Result<MailMutationJournal.Reconciliation, MailFailure> {
            lock.lock(); defer { lock.unlock() }
            _reconcileCalls += 1
            try reconcileHook?()
            return _reconcileResult
        }

        var seams: MailMoveOrchestration.Seams {
            MailMoveOrchestration.Seams(
                identity: { [self] _ in
                    try performIdentityCall().get()
                },
                reconcile: { [self] _ in
                    try performReconcileCall().get()
                }
            )
        }
    }

    private func rehearsal(
        journal: MailMutationJournal,
        exchange: Exchange
    ) -> MailMoveOrchestration {
        MailMoveOrchestration(journal: journal, seams: exchange.seams)
    }

    private func isReplay(_ outcome: MailMoveOrchestration.Outcome, _ state: MailMutationJournal.State) -> Bool {
        if case .replay(let actual) = outcome { return actual == state }
        return false
    }

    // MARK: - Read-only snapshot

    @Test("Snapshot of an unknown request is nil and creates no directory or receipt")
    func snapshotMissingCreatesNothing() throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        let journal = MailMutationJournal(directory: directory)
        let op = operation()

        let snapshot = try journal.snapshot(requestID: op.requestID, digest: op.digest)
        #expect(snapshot == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Snapshot fails closed for a digest conflict and for a corrupt receipt")
    func snapshotFailsClosed() throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        let journal = MailMutationJournal(directory: directory)
        let first = operation()
        let other = operation(requestID: first.requestID, destination: "Trash")
        let reserved = try journal.reserve(requestID: first.requestID, digest: first.digest, provenance: reservation(first))
        #expect(reserved == nil)

        #expect(throws: MailFailure.invalidMessage) {
            try journal.snapshot(requestID: first.requestID, digest: other.digest)
        }
        let receipt = directory.appendingPathComponent("mutation-" + first.requestID.uuidString + ".json")
        try Data("not a receipt".utf8).write(to: receipt)
        #expect(throws: MailFailure.invalidMessage) {
            try journal.snapshot(requestID: first.requestID, digest: first.digest)
        }
        #expect(FileManager.default.fileExists(atPath: receipt.path), "corrupt receipts stay preserved")
    }

    // MARK: - Replay without the source message

    @Test("A completed retry replays without reading the (possibly gone) source")
    func completedReplayNeedsNoSource() async throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        let journal = MailMutationJournal(directory: directory)
        let exchange = Exchange()
        exchange.setIdentity(.failure(.messageNotFound))
        let op = operation()
        try journal.reserve(requestID: op.requestID, digest: op.digest, provenance: reservation(op))
        try journal.finish(requestID: op.requestID, digest: op.digest, state: .completed)

        let outcome = try await rehearsal(journal: journal, exchange: exchange).execute(op)
        #expect(isReplay(outcome, .completed))
        #expect(exchange.identityCalls == 0)
        #expect(exchange.reconcileCalls == 0)
    }

    @Test("A notStarted retry replays its terminal state without network access")
    func notStartedReplay() async throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        let journal = MailMutationJournal(directory: directory)
        let exchange = Exchange()
        let op = operation()
        try journal.reserve(requestID: op.requestID, digest: op.digest, provenance: reservation(op))
        try journal.finish(requestID: op.requestID, digest: op.digest, state: .notStarted)

        let outcome = try await rehearsal(journal: journal, exchange: exchange).execute(op)
        #expect(isReplay(outcome, .notStarted))
        #expect(exchange.identityCalls == 0)
        #expect(exchange.reconcileCalls == 0)
    }

    // MARK: - Ambiguous receipts

    @Test("An unknown receipt reconciles from persisted provenance without reading the source")
    func unknownReconcilesFromPersistedProvenance() async throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        let journal = MailMutationJournal(directory: directory)
        let exchange = Exchange()
        exchange.setIdentity(.failure(.messageNotFound))
        exchange.setReconcile(.success(.completed(destinationUID: "900", destinationMailboxVersion: "12")))
        let op = operation()
        try journal.reserve(requestID: op.requestID, digest: op.digest, provenance: reservation(op))

        let outcome = try await rehearsal(journal: journal, exchange: exchange).execute(op)
        guard case .reconciledCompleted(let uid, let version, let persisted) = outcome else {
            Issue.record("expected reconciled completion, got \(outcome)")
            return
        }
        #expect(uid == "900")
        #expect(version == "12")
        #expect(persisted, "a healthy receipt store must report the completion as persisted")
        #expect(exchange.identityCalls == 0)
        #expect(exchange.reconcileCalls == 1)
        let snapshot = try journal.snapshot(requestID: op.requestID, digest: op.digest)
        #expect(snapshot?.state == .completed)
    }

    @Test("A proven-not-submitted receipt is re-permitted exactly once under ownership")
    func notSubmittedRepermitsUnderOwnership() async throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        let journal = MailMutationJournal(directory: directory)
        let exchange = Exchange()
        exchange.setReconcile(.success(.notSubmitted))
        let op = operation()
        try journal.reserve(requestID: op.requestID, digest: op.digest, provenance: reservation(op))

        let first = try await rehearsal(journal: journal, exchange: exchange).execute(op)
        guard case .firstAttempt(let attempt) = first else {
            Issue.record("expected one re-permitted attempt, got \(first)")
            return
        }
        // The re-permitted attempt is reserved again, still unknown until the
        // caller performs and finalizes the move.
        #expect(try journal.snapshot(requestID: op.requestID, digest: op.digest)?.state == .mutationUnknown)

        // While that attempt is alive, a second caller must not reconcile or
        // mutate: the read-only "not there yet" verdict must not preempt it.
        let second = try await rehearsal(journal: journal, exchange: exchange).execute(op)
        guard case .uncertain(let reason) = second else {
            Issue.record("expected an ownership block, got \(second)")
            return
        }
        #expect(reason == "concurrentAttemptActive")
        #expect(exchange.reconcileCalls == 1)

        // Release without finalizing (simulating a crashed attempt): now a
        // later caller may reconcile recovery again.
        attempt.release()
        try journal.finish(requestID: op.requestID, digest: op.digest, state: .mutationUnknown)
        exchange.setReconcile(.success(.ambiguous(reason: "copy present but source intact")))
        let third = try await rehearsal(journal: journal, exchange: exchange).execute(op)
        guard case .uncertain(let finalReason) = third else {
            Issue.record("expected an explicit ambiguous verdict, got \(third)")
            return
        }
        #expect(finalReason == "copy present but source intact")
        #expect(exchange.reconcileCalls == 2)
    }

    @Test("Artifacts reserved by earlier builds without provenance stay uncertain and are never re-moved")
    func legacyReceiptStaysUncertain() async throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let exchange = Exchange()
        let op = operation()
        let receipt = directory.appendingPathComponent("mutation-" + op.requestID.uuidString + ".json")
        let legacy = ["digest": op.digest, "state": "mutationUnknown"]
        try JSONEncoder().encode(legacy).write(to: receipt)

        let outcome = try await rehearsal(journal: MailMutationJournal(directory: directory), exchange: exchange).execute(op)
        guard case .uncertain(let reason) = outcome else {
            Issue.record("expected an honest uncertainty, got \(outcome)")
            return
        }
        #expect(reason == "legacyReceiptNoProvenance")
        #expect(exchange.identityCalls == 0)
        #expect(exchange.reconcileCalls == 0)
        let snapshot = try MailMutationJournal(directory: directory)
            .snapshot(requestID: op.requestID, digest: op.digest)
        #expect(snapshot?.state == .mutationUnknown)
    }

    // MARK: - First attempt and its race window

    @Test("A truly first request with a missing source fails honestly and mints nothing")
    func firstAttemptMissingSourceFails() async throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        let journal = MailMutationJournal(directory: directory)
        let exchange = Exchange()
        exchange.setIdentity(.failure(.messageNotFound))
        let op = operation()

        await #expect(throws: MailFailure.messageNotFound) {
            try await rehearsal(journal: journal, exchange: exchange).execute(op)
        }
        let snapshot = try journal.snapshot(requestID: op.requestID, digest: op.digest)
        #expect(snapshot == nil)
        #expect(exchange.reconcileCalls == 0)
    }

    @Test("A silent first attempt is granted ownership; the receipt starts unknown")
    func firstAttemptGrantsOwnership() async throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        let journal = MailMutationJournal(directory: directory)
        let exchange = Exchange()
        let op = operation()

        let outcome = try await rehearsal(journal: journal, exchange: exchange).execute(op)
        guard case .firstAttempt(let attempt) = outcome else {
            Issue.record("expected a first attempt, got \(outcome)")
            return
        }
        #expect(attempt.requestID == op.requestID)
        #expect(attempt.digest == op.digest)
        #expect(try journal.snapshot(requestID: op.requestID, digest: op.digest)?.state == .mutationUnknown)
        // The source identity is captured exactly once for a first attempt.
        #expect(exchange.identityCalls == 1)
        attempt.release()
    }

    @Test("A source read that fails after a concurrent completion replays completed, not notFound")
    func sourceReadRaceRecoversConcurrentCompletion() async throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        let journal = MailMutationJournal(directory: directory)
        let exchange = Exchange()
        let op = operation()
        // Pre-snapshot sees nothing; while the (slow) source identity read is
        // in flight, a concurrent execution of the SAME request reserves,
        // moves the mail and finalizes `completed`. Our identity read then
        // reports the source gone.
        exchange.identityHook = {
            let other = MailMutationJournal(directory: directory)
            let provenance = MailMutationJournal.Provenance(
                accountID: op.accountID,
                action: op.action,
                sourceFolder: op.sourceFolder,
                destination: op.destination,
                uid: op.uid,
                mailboxVersion: op.mailboxVersion,
                messageID: "<stable@example.test>",
                byteCount: 2048
            )
            _ = try other.reserve(requestID: op.requestID, digest: op.digest, provenance: provenance)
            try other.finish(requestID: op.requestID, digest: op.digest, state: .completed)
        }
        exchange.setIdentity(.failure(.messageNotFound))

        let outcome = try await rehearsal(journal: journal, exchange: exchange).execute(op)
        #expect(isReplay(outcome, .completed))
        #expect(exchange.identityCalls == 1)
        #expect(exchange.reconcileCalls == 0)
    }

    @Test("A source read race against a still-live owner stays uncertain instead of reporting notFound")
    func sourceReadRaceAgainstLiveOwner() async throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        let journal = MailMutationJournal(directory: directory)
        let exchange = Exchange()
        let op = operation()
        let other = MailMutationJournal(directory: directory)
        let provenance = reservation(op)
        final class LockBox: @unchecked Sendable { var value: MailMutationJournal.MailOwnerLock? }
        let lockBox = LockBox()
        exchange.identityHook = {
            _ = try other.reserve(requestID: op.requestID, digest: op.digest, provenance: provenance)
            // Another execution is still mid-mutation and owns the request.
            lockBox.value = other.acquireOwnerLock(requestID: op.requestID)
        }
        exchange.setIdentity(.failure(.messageNotFound))

        let outcome = try await rehearsal(journal: journal, exchange: exchange).execute(op)
        guard case .uncertain(let reason) = outcome else {
            Issue.record("expected an ownership block, got \(outcome)")
            return
        }
        #expect(reason == "concurrentAttemptActive")
        #expect(exchange.reconcileCalls == 0)
        lockBox.value?.release()
    }

    @Test("A source read race against a corrupt receipt fails closed, not as notFound")
    func sourceReadRaceCorruptReceipt() async throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        let journal = MailMutationJournal(directory: directory)
        let exchange = Exchange()
        let op = operation()
        let receipt = directory.appendingPathComponent("mutation-" + op.requestID.uuidString + ".json")
        exchange.identityHook = {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("garbage".utf8).write(to: receipt)
        }
        exchange.setIdentity(.failure(.messageNotFound))

        await #expect(throws: MailFailure.invalidMessage) {
            try await rehearsal(journal: journal, exchange: exchange).execute(op)
        }
    }

    // MARK: - Non-preemptible ownership

    @Test("An owner is never preempted by elapsed wall-clock time; only release frees it")
    func ownershipOutlivesWallClock() async throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        let journal = MailMutationJournal(directory: directory)
        let exchange = Exchange()
        let op = operation()

        let first = try await rehearsal(journal: journal, exchange: exchange).execute(op)
        guard case .firstAttempt(let attempt) = first else {
            Issue.record("expected the first ownership, got \(first)")
            return
        }
        // There is deliberately no expiry input to fast-forward: hold the
        // attempt across repeated probes (and real waiting) and observe that
        // nothing but release can hand ownership over.
        for _ in 0..<4 {
            try await Task.sleep(nanoseconds: 25_000_000)
            let probe = try await rehearsal(journal: journal, exchange: exchange).execute(op)
            guard case .uncertain(let reason) = probe else {
                Issue.record("a second caller obtained mutation rights while the owner was alive: \(probe)")
                continue
            }
            #expect(reason == "concurrentAttemptActive")
        }
        attempt.release()
        try journal.finish(requestID: op.requestID, digest: op.digest, state: .completed)
        let replay = try await rehearsal(journal: journal, exchange: exchange).execute(op)
        #expect(isReplay(replay, .completed))
    }

    @Test("Two journal instances over one directory grant only one mutation owner")
    func twoInstancesShareOneOwner() async throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        let firstJournal = MailMutationJournal(directory: directory)
        let secondJournal = MailMutationJournal(directory: directory)
        let op = operation()

        let first = try await rehearsal(journal: firstJournal, exchange: Exchange()).execute(op)
        guard case .firstAttempt(let attempt) = first else {
            Issue.record("expected the first ownership, got \(first)")
            return
        }
        let exchange = Exchange()
        let second = try await rehearsal(journal: secondJournal, exchange: exchange).execute(op)
        guard case .uncertain(let reason) = second else {
            Issue.record("the second instance obtained mutation rights: \(second)")
            return
        }
        #expect(reason == "concurrentAttemptActive")
        #expect(exchange.reconcileCalls == 0)
        #expect(exchange.identityCalls == 0)

        // Recovery is possible only after the old caller releases.
        try firstJournal.finish(requestID: op.requestID, digest: op.digest, state: .completed)
        attempt.release()
        let afterRelease = try await rehearsal(journal: secondJournal, exchange: exchange).execute(op)
        #expect(isReplay(afterRelease, .completed))
    }

    @Test("Owner lock probes exclude a second instance and free on release")
    func ownerLockIsExclusiveAcrossInstances() throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        let first = MailMutationJournal(directory: directory)
        let second = MailMutationJournal(directory: directory)
        let requestID = UUID()

        let held = first.acquireOwnerLock(requestID: requestID)
        #expect(held != nil)
        #expect(second.acquireOwnerLock(requestID: requestID) == nil)
        held?.release()
        let reclaimed = second.acquireOwnerLock(requestID: requestID)
        #expect(reclaimed != nil)
        reclaimed?.release()
    }

    @Test("Concurrent reserve through two instances has exactly one winner")
    func concurrentReserveSingleWinner() throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        let journals = [
            MailMutationJournal(directory: directory),
            MailMutationJournal(directory: directory)
        ]
        let op = operation()
        let provenance = reservation(op)
        final class Tally: @unchecked Sendable { var value = 0 }
        let lock = NSLock()
        let winners = Tally()
        let failures = Tally()
        let gate = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        for index in 0..<8 {
            DispatchQueue.global().async(group: group) {
                gate.wait()
                let journal = journals[index % journals.count]
                // `try?` flattens optionals here (nil means both "authorized"
                // and "threw"), so keep the two outcomes distinct.
                var authorized = false
                var failed = false
                do {
                    authorized = try journal.reserve(
                        requestID: op.requestID,
                        digest: op.digest,
                        provenance: provenance
                    ) == nil
                } catch {
                    failed = true
                }
                lock.lock()
                if authorized { winners.value += 1 } else if failed { failures.value += 1 }
                lock.unlock()
            }
        }
        for _ in 0..<8 { gate.signal() }
        group.wait()

        #expect(winners.value == 1, "expected exactly one authorization, got \(winners.value) (failures: \(failures.value))")
        #expect(failures.value == 0)
        let snapshot = try journals[0].snapshot(requestID: op.requestID, digest: op.digest)
        #expect(snapshot?.state == .mutationUnknown)
        #expect(snapshot?.provenance == provenance)
    }

    @Test("A digest conflict between request identities fails closed before any network seam")
    func digestConflictFailsClosed() async throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        let journal = MailMutationJournal(directory: directory)
        let exchange = Exchange()
        let first = operation()
        let conflicting = operation(requestID: first.requestID, destination: "Trash")
        try journal.reserve(requestID: first.requestID, digest: first.digest, provenance: reservation(first))

        await #expect(throws: MailFailure.invalidMessage) {
            try await rehearsal(journal: journal, exchange: exchange).execute(conflicting)
        }
        #expect(exchange.identityCalls == 0)
        #expect(exchange.reconcileCalls == 0)
    }



    // MARK: - Tool wiring (receipt recovery before network/credentials)

    /// Models the production resolver: resolving a server-declared special
    /// folder reads the account password and opens the network. The test
    /// counts both so a replay cannot silently touch either.
    private final class ResolverSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var destinations = 0
        private var credentials = 0
        private let destination: String?
        private let failure: Error?

        init(destination: String? = nil, failure: Error? = nil) {
            self.destination = destination
            self.failure = failure
        }

        var destinationCalls: Int { lock.lock(); defer { lock.unlock() }; return destinations }
        var credentialCalls: Int { lock.lock(); defer { lock.unlock() }; return credentials }

        /// Models production: resolving a server-declared special folder
        /// reads the account password and opens the network. The counts make
        /// any unexpected lookup visible.
        func resolve(_ requested: MailMoveRequest) throws -> String {
            lock.lock(); defer { lock.unlock() }
            destinations += 1
            credentials += 1
            if let failure { throw failure }
            return destination ?? "resolved-\(requested.action)"
        }
    }

    private func seedReceipt(
        _ journal: MailMutationJournal,
        request: MailMoveRequest,
        destination: String,
        state: MailMutationJournal.State,
        includeProvenance: Bool = true
    ) throws -> MailMoveOperation {
        let operation = request.operation(destination: destination)
        try journal.reserve(
            requestID: request.requestID,
            digest: operation.digest,
            provenance: includeProvenance ? MailMutationJournal.Provenance(
                accountID: request.accountID,
                action: request.action,
                sourceFolder: request.sourceFolder,
                destination: destination,
                uid: request.uid,
                mailboxVersion: request.mailboxVersion,
                messageID: "<stable@example.test>",
                byteCount: 2048
            ) : nil
        )
        if state != .mutationUnknown {
            try journal.finish(requestID: request.requestID, digest: operation.digest, state: state)
        }
        return operation
    }

    /// Writes the pre-provenance receipt shape (digest + state only) exactly
    /// as an earlier build left it.
    @discardableResult
    private func seedLegacyReceipt(
        requestID: UUID,
        digest: String,
        state: MailMutationJournal.State,
        in directory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let receipt = directory.appendingPathComponent("mutation-" + requestID.uuidString + ".json")
        try JSONEncoder().encode(["digest": digest, "state": state.rawValue]).write(to: receipt)
        return receipt
    }

    @Test("A completed archive retry replays offline with zero destination, credential and source lookups")
    func completedArchiveReplaysBeforeNetwork() async throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        let journal = MailMutationJournal(directory: directory)
        let request = MailMoveRequest(
            requestID: UUID(),
            accountID: accountID,
            action: "archive",
            sourceFolder: "INBOX",
            uid: "42",
            mailboxVersion: "777"
        )
        _ = try seedReceipt(journal, request: request, destination: "Archive", state: .completed)

        // Both seams would fail if reached: the receipt alone must answer.
        let exchange = Exchange()
        exchange.setIdentity(.failure(.messageNotFound))
        exchange.setReconcile(.failure(.messageNotFound))
        let orchestration = MailMoveOrchestration(journal: journal, seams: exchange.seams)
        let resolver = ResolverSpy()

        let preparation = try await orchestration.prepare(request) { try resolver.resolve($0) }
        guard case .ready(let operation) = preparation else {
            Issue.record("expected a bound operation, got \(preparation)")
            return
        }
        // The stored destination is reused; nothing is re-resolved.
        #expect(operation.destination == "Archive")
        #expect(resolver.destinationCalls == 0)
        #expect(resolver.credentialCalls == 0)

        let outcome = try await orchestration.execute(operation)
        #expect(isReplay(outcome, .completed))
        #expect(exchange.identityCalls == 0)
        #expect(exchange.reconcileCalls == 0)
        #expect(resolver.destinationCalls == 0)
        #expect(resolver.credentialCalls == 0)
    }

    @Test("prepare rejects provenance belonging to a different request identity")
    func prepareRejectsForeignProvenance() async throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        let journal = MailMutationJournal(directory: directory)
        let seededRequest = MailMoveRequest(
            requestID: UUID(),
            accountID: accountID,
            action: "move",
            sourceFolder: "INBOX",
            uid: "42",
            mailboxVersion: "777",
            destination: "Archive"
        )
        _ = try seedReceipt(journal, request: seededRequest, destination: "Archive", state: .completed)
        let orchestration = MailMoveOrchestration(journal: journal, seams: Exchange().seams)

        func expectRejected(_ request: MailMoveRequest) async {
            await #expect(throws: MailFailure.invalidMessage) {
                _ = try await orchestration.prepare(request) { request in "unexpected-\(request.action)" }
            }
        }
        // Different account.
        await expectRejected(MailMoveRequest(
            requestID: seededRequest.requestID, accountID: UUID(), action: "move",
            sourceFolder: "INBOX", uid: "42", mailboxVersion: "777", destination: "Archive"))
        // Different action.
        await expectRejected(MailMoveRequest(
            requestID: seededRequest.requestID, accountID: accountID, action: "trash",
            sourceFolder: "INBOX", uid: "42", mailboxVersion: "777"))
        // Different UID.
        await expectRejected(MailMoveRequest(
            requestID: seededRequest.requestID, accountID: accountID, action: "move",
            sourceFolder: "INBOX", uid: "43", mailboxVersion: "777", destination: "Archive"))
        // Different mailbox version.
        await expectRejected(MailMoveRequest(
            requestID: seededRequest.requestID, accountID: accountID, action: "move",
            sourceFolder: "INBOX", uid: "42", mailboxVersion: "778", destination: "Archive"))
        // Different explicit destination for a move.
        await expectRejected(MailMoveRequest(
            requestID: seededRequest.requestID, accountID: accountID, action: "move",
            sourceFolder: "INBOX", uid: "42", mailboxVersion: "777", destination: "Elsewhere"))
        // Different source folder.
        await expectRejected(MailMoveRequest(
            requestID: seededRequest.requestID, accountID: accountID, action: "move",
            sourceFolder: "Sent", uid: "42", mailboxVersion: "777", destination: "Archive"))
    }

    @Test("A first archive/trash request resolves once; a first move never does")
    func firstRequestResolvesOnce() async throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        let journal = MailMutationJournal(directory: directory)
        let orchestration = MailMoveOrchestration(journal: journal, seams: Exchange().seams)
        let resolver = ResolverSpy()

        let archive = MailMoveRequest(
            requestID: UUID(), accountID: accountID, action: "archive",
            sourceFolder: "INBOX", uid: "42", mailboxVersion: "777")
        let preparedArchive = try await orchestration.prepare(archive) { try resolver.resolve($0) }
        guard case .ready(let archiveOperation) = preparedArchive else {
            Issue.record("expected a first archive operation, got \(preparedArchive)")
            return
        }
        #expect(archiveOperation.destination == "resolved-archive")
        #expect(resolver.destinationCalls == 1)
        #expect(resolver.credentialCalls == 1)

        let move = MailMoveRequest(
            requestID: UUID(), accountID: accountID, action: "move",
            sourceFolder: "INBOX", uid: "42", mailboxVersion: "777", destination: "Target")
        let preparedMove = try await orchestration.prepare(move) { try resolver.resolve($0) }
        guard case .ready(let moveOperation) = preparedMove else {
            Issue.record("expected a first move operation, got \(preparedMove)")
            return
        }
        #expect(moveOperation.destination == "Target")
        // The explicit move destination needs no server lookup at all.
        #expect(resolver.destinationCalls == 1)
    }

    // MARK: - Legacy terminal receipts (the one online resolution exception)

    @Test("Terminal legacy archive/trash receipts are rebound by one resolution and replayed without a mutation")
    func legacyTerminalArchiveRebindsAndReplays() async throws {
        for action in ["archive", "trash"] {
            for state in [MailMutationJournal.State.completed, .notStarted] {
                let directory = makeDirectory()
                defer { cleanup(directory) }
                let request = MailMoveRequest(
                    requestID: UUID(), accountID: accountID, action: action,
                    sourceFolder: "INBOX", uid: "42", mailboxVersion: "777")
                let operation = request.operation(destination: "Archive")
                try seedLegacyReceipt(
                    requestID: request.requestID,
                    digest: operation.digest,
                    state: state,
                    in: directory
                )
                let journal = MailMutationJournal(directory: directory)
                let exchange = Exchange()
                // Both network seams fail if reached: the terminal receipt
                // alone must answer after the one binding resolution.
                exchange.setIdentity(.failure(.messageNotFound))
                exchange.setReconcile(.failure(.messageNotFound))
                let resolver = ResolverSpy(destination: "Archive")
                let orchestration = MailMoveOrchestration(journal: journal, seams: exchange.seams)

                let preparation = try await orchestration.prepare(request) { try resolver.resolve($0) }
                guard case .ready(let bound) = preparation else {
                    Issue.record("expected a \(action)/\(state) legacy rebind, got \(preparation)")
                    continue
                }
                #expect(bound.destination == "Archive")
                #expect(bound.digest == operation.digest)
                #expect(resolver.destinationCalls == 1, "the legacy receipt may use exactly one resolver call")
                #expect(resolver.credentialCalls == 1)

                let outcome = try await orchestration.execute(bound)
                #expect(isReplay(outcome, state))
                #expect(exchange.identityCalls == 0)
                #expect(exchange.reconcileCalls == 0)
                #expect(resolver.destinationCalls == 1, "replay itself must not resolve again")
                let snapshot = try journal.snapshot(requestID: request.requestID, digest: operation.digest)
                #expect(snapshot?.state == state)
                #expect(snapshot?.provenance == nil, "a legacy receipt is verified, never rewritten with invented provenance")
            }
        }
    }

    @Test("An offline legacy terminal archive stays uncertain and keeps the old receipt byte-for-byte")
    func legacyTerminalArchiveOfflineStaysUncertain() async throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        let request = MailMoveRequest(
            requestID: UUID(), accountID: accountID, action: "archive",
            sourceFolder: "INBOX", uid: "42", mailboxVersion: "777")
        let operation = request.operation(destination: "Archive")
        let receipt = try seedLegacyReceipt(
            requestID: request.requestID,
            digest: operation.digest,
            state: .completed,
            in: directory
        )
        let original = try Data(contentsOf: receipt)
        let journal = MailMutationJournal(directory: directory)
        let resolver = ResolverSpy(failure: MailFailure.connectionFailed)
        let orchestration = MailMoveOrchestration(journal: journal, seams: Exchange().seams)

        let preparation = try await orchestration.prepare(request) { try resolver.resolve($0) }
        guard case .uncertain(let reason) = preparation else {
            Issue.record("expected an honest limitation while offline, got \(preparation)")
            return
        }
        #expect(reason == "legacyReceiptUnverifiable")
        #expect(resolver.destinationCalls == 1, "the resolver is attempted but its failure is not guessed around")
        #expect(resolver.credentialCalls == 1)
        #expect(try Data(contentsOf: receipt) == original, "the old receipt must not be modified")
        #expect(try journal.snapshot(requestID: request.requestID, digest: operation.digest)?.state == .completed)
    }

    @Test("A legacy unknown archive is never resolved or inferred from the folder")
    func legacyUnknownArchiveNeverResolves() async throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        let request = MailMoveRequest(
            requestID: UUID(), accountID: accountID, action: "archive",
            sourceFolder: "INBOX", uid: "42", mailboxVersion: "777")
        let operation = request.operation(destination: "Archive")
        try seedLegacyReceipt(
            requestID: request.requestID,
            digest: operation.digest,
            state: .mutationUnknown,
            in: directory
        )
        let journal = MailMutationJournal(directory: directory)
        let exchange = Exchange()
        let resolver = ResolverSpy(destination: "Archive")
        let orchestration = MailMoveOrchestration(journal: journal, seams: exchange.seams)

        let preparation = try await orchestration.prepare(request) { try resolver.resolve($0) }
        guard case .uncertain(let reason) = preparation else {
            Issue.record("an ambiguous legacy receipt must stay uncertain, got \(preparation)")
            return
        }
        #expect(reason == "legacyReceiptNoProvenance")
        #expect(resolver.destinationCalls == 0, "a folder cannot prove whether an unknown mutation was submitted")
        #expect(resolver.credentialCalls == 0)

        // Executing the bound operation directly must also stay uncertain
        // without touching the source or repeating the mutation.
        let outcome = try await orchestration.execute(operation)
        guard case .uncertain(let executionReason) = outcome else {
            Issue.record("the legacy unknown receipt was re-executed: \(outcome)")
            return
        }
        #expect(executionReason == "legacyReceiptNoProvenance")
        #expect(exchange.identityCalls == 0)
        #expect(exchange.reconcileCalls == 0)
        #expect(try journal.snapshot(requestID: request.requestID, digest: operation.digest)?.state == .mutationUnknown)
    }

    @Test("A legacy terminal rebind rejects foreign account, action, UID and destination facts")
    func legacyTerminalForeignFactsFailClosed() async throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        let seeded = MailMoveRequest(
            requestID: UUID(), accountID: accountID, action: "archive",
            sourceFolder: "INBOX", uid: "42", mailboxVersion: "777")
        let seededOperation = seeded.operation(destination: "Archive")
        let receipt = try seedLegacyReceipt(
            requestID: seeded.requestID,
            digest: seededOperation.digest,
            state: .completed,
            in: directory
        )
        let original = try Data(contentsOf: receipt)
        let journal = MailMutationJournal(directory: directory)
        let exchange = Exchange()
        let orchestration = MailMoveOrchestration(journal: journal, seams: exchange.seams)

        func expectRejected(_ request: MailMoveRequest, resolved destination: String) async {
            let resolver = ResolverSpy(destination: destination)
            await #expect(throws: MailFailure.invalidMessage) {
                _ = try await orchestration.prepare(request) { try resolver.resolve($0) }
            }
            #expect(resolver.destinationCalls == 1)
        }
        // Foreign account.
        await expectRejected(MailMoveRequest(
            requestID: seeded.requestID, accountID: UUID(), action: "archive",
            sourceFolder: "INBOX", uid: "42", mailboxVersion: "777"), resolved: "Archive")
        // Foreign action.
        await expectRejected(MailMoveRequest(
            requestID: seeded.requestID, accountID: accountID, action: "trash",
            sourceFolder: "INBOX", uid: "42", mailboxVersion: "777"), resolved: "Archive")
        // Foreign UID.
        await expectRejected(MailMoveRequest(
            requestID: seeded.requestID, accountID: accountID, action: "archive",
            sourceFolder: "INBOX", uid: "43", mailboxVersion: "777"), resolved: "Archive")
        // Foreign source folder.
        await expectRejected(MailMoveRequest(
            requestID: seeded.requestID, accountID: accountID, action: "archive",
            sourceFolder: "Sent", uid: "42", mailboxVersion: "777"), resolved: "Archive")
        // Foreign mailbox version.
        await expectRejected(MailMoveRequest(
            requestID: seeded.requestID, accountID: accountID, action: "archive",
            sourceFolder: "INBOX", uid: "42", mailboxVersion: "778"), resolved: "Archive")
        // A server folder that does not reproduce the stored digest.
        await expectRejected(seeded, resolved: "Archives")

        #expect(exchange.identityCalls == 0)
        #expect(exchange.reconcileCalls == 0)
        let snapshot = try journal.snapshot(requestID: seeded.requestID, digest: seededOperation.digest)
        #expect(snapshot?.state == .completed)
        #expect(snapshot?.provenance == nil)
        #expect(try Data(contentsOf: receipt) == original, "failed bindings must not rewrite the legacy receipt")
    }

    @Test("A legacy move receipt can be bound offline from its explicit destination")
    func legacyMoveBindsOffline() async throws {
        let directory = makeDirectory()
        defer { cleanup(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let requestID = UUID()
        let request = MailMoveRequest(
            requestID: requestID, accountID: accountID, action: "move",
            sourceFolder: "INBOX", uid: "42", mailboxVersion: "777", destination: "Archive")
        let operation = request.operation(destination: "Archive")
        let receipt = directory.appendingPathComponent("mutation-" + requestID.uuidString + ".json")
        let legacy = ["digest": operation.digest, "state": "completed"]
        try JSONEncoder().encode(legacy).write(to: receipt)
        let journal = MailMutationJournal(directory: directory)
        let orchestration = MailMoveOrchestration(journal: journal, seams: Exchange().seams)
        let resolver = ResolverSpy()

        let preparation = try await orchestration.prepare(request) { try resolver.resolve($0) }
        guard case .ready(let bound) = preparation else {
            Issue.record("expected an offline binding for an explicit move, got \(preparation)")
            return
        }
        #expect(bound.digest == operation.digest)
        #expect(resolver.destinationCalls == 0)
        #expect(resolver.credentialCalls == 0)
        let outcome = try await orchestration.execute(bound)
        #expect(isReplay(outcome, .completed))
    }

    // MARK: - Receipt write-back failures (storage problems are not outcomes)

    @Test("A verified completion survives a failed receipt write and reports receiptPersisted=false")
    func completedWriteFailureKeepsServerResult() async throws {
        let directory = makeDirectory()
        defer {
            try? setMailTestPermissions(0o755, of: directory)
            cleanup(directory)
        }
        let journal = MailMutationJournal(directory: directory)
        let exchange = Exchange()
        exchange.setReconcile(.success(.completed(destinationUID: "900", destinationMailboxVersion: "12")))
        let op = operation()
        let facts = reservation(op)
        try journal.reserve(requestID: op.requestID, digest: op.digest, provenance: facts)
        // The reconcile seam proves the mutation landed, then the fixture
        // store becomes read-only before the completion can be written back.
        exchange.reconcileHook = { try setMailTestPermissions(0o555, of: directory) }

        let outcome = try await rehearsal(journal: journal, exchange: exchange).execute(op)
        guard case .reconciledCompleted(let uid, let version, let persisted) = outcome else {
            Issue.record("a storage failure turned a verified completion into \(outcome)")
            return
        }
        #expect(uid == "900")
        #expect(version == "12")
        #expect(!persisted, "the failed write must be visible, never silently claimed as saved")

        // The old ambiguous receipt is intact and still drives the retry.
        let snapshot = try journal.snapshot(requestID: op.requestID, digest: op.digest)
        #expect(snapshot?.state == .mutationUnknown)
        #expect(snapshot?.provenance == facts)

        // Ownership was released; recovery works once storage is healthy.
        try setMailTestPermissions(0o755, of: directory)
        let other = MailMutationJournal(directory: directory)
        let probe = other.acquireOwnerLock(requestID: op.requestID)
        #expect(probe != nil, "a failed write-back must still release its owner lock")
        probe?.release()

        exchange.reconcileHook = nil
        let retry = try await rehearsal(journal: other, exchange: exchange).execute(op)
        guard case .reconciledCompleted(let retryUID, _, let retryPersisted) = retry else {
            Issue.record("expected the verified completion again, got \(retry)")
            return
        }
        #expect(retryUID == "900")
        #expect(retryPersisted)
        #expect(try journal.snapshot(requestID: op.requestID, digest: op.digest)?.state == .completed)
    }

    @Test("A not-submitted receipt rewrite failure grants no attempt and releases ownership")
    func notSubmittedWriteFailureGrantsNothing() async throws {
        let directory = makeDirectory()
        defer {
            try? setMailTestPermissions(0o755, of: directory)
            cleanup(directory)
        }
        let journal = MailMutationJournal(directory: directory)
        let exchange = Exchange()
        exchange.setReconcile(.success(.notSubmitted))
        let op = operation()
        let facts = reservation(op)
        try journal.reserve(requestID: op.requestID, digest: op.digest, provenance: facts)
        // The read-only proof arrives, but the notStarted rewrite cannot be
        // stored.
        exchange.reconcileHook = { try setMailTestPermissions(0o555, of: directory) }

        let outcome = try await rehearsal(journal: journal, exchange: exchange).execute(op)
        guard case .uncertain(let reason) = outcome else {
            Issue.record("a failed notSubmitted rewrite handed out \(outcome)")
            return
        }
        #expect(reason == "storageUnavailable", "a storage failure must not masquerade as concurrent activity: \(reason)")
        #expect(exchange.reconcileCalls == 1)

        // No receipt rewrite and no mutation right escaped.
        try setMailTestPermissions(0o755, of: directory)
        #expect(try journal.snapshot(requestID: op.requestID, digest: op.digest)?.state == .mutationUnknown)
        let other = MailMutationJournal(directory: directory)
        let probe = other.acquireOwnerLock(requestID: op.requestID)
        #expect(probe != nil, "the failed rewrite must still release its owner lock")
        probe?.release()

        // With storage restored the same verdict grants exactly one attempt.
        exchange.reconcileHook = nil
        let retry = try await rehearsal(journal: other, exchange: exchange).execute(op)
        guard case .firstAttempt(let attempt) = retry else {
            Issue.record("expected recovery after storage is restored, got \(retry)")
            return
        }
        #expect(try journal.snapshot(requestID: op.requestID, digest: op.digest)?.state == .mutationUnknown)
        attempt.release()
    }

    @Test("An owner-lock IO failure reports storageUnavailable, never a live concurrent attempt")
    func ownerLockIOFailureIsNotConcurrency() async throws {
        let directory = makeDirectory()
        defer {
            try? setMailTestPermissions(0o755, of: directory)
            cleanup(directory)
        }
        let journal = MailMutationJournal(directory: directory)
        let exchange = Exchange()
        exchange.setReconcile(.success(.notSubmitted))
        let op = operation()
        try journal.reserve(requestID: op.requestID, digest: op.digest, provenance: reservation(op))
        try setMailTestPermissions(0o555, of: directory)

        let outcome = try await rehearsal(journal: journal, exchange: exchange).execute(op)
        guard case .uncertain(let reason) = outcome else {
            Issue.record("an owner-lock IO failure produced \(outcome)")
            return
        }
        #expect(reason == "storageUnavailable")
        #expect(exchange.reconcileCalls == 0, "no reconciliation or mutation may run without ownership")

        try setMailTestPermissions(0o755, of: directory)
        #expect(try journal.snapshot(requestID: op.requestID, digest: op.digest)?.state == .mutationUnknown)
        let recovered = try await rehearsal(journal: journal, exchange: exchange).execute(op)
        guard case .firstAttempt(let attempt) = recovered else {
            Issue.record("expected ownership recovery once storage is healthy, got \(recovered)")
            return
        }
        attempt.release()
    }
}
