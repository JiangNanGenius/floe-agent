// FloeAppTests — the bounded edit-entry acknowledgement and the Office exit
// state machine.
//
// The Build 223 PPT edit stall could wedge a session for good when the native
// host's edit-entry completion was lost: the edit acknowledgement suspended
// forever, `operating` never cleared, and every later recovery was refused.
// `OfficeEditEntryAck` bounds that wait — the first resolver (host callback or
// timeout) wins, and a timeout reads as unverified-read-only so the session's
// re-probe and fallback decide from the engine's real state. These tests pin
// the one-shot semantics the bounded edit path relies on.
//
// The same one-shot contract protects every exit path: `OfficeSaveReceipt`
// must replay its settled result verbatim to late waiters (never degrade a
// bounded save failure into a fabricated success and never orphan a second
// waiter's continuation), and `OfficeFileSession` teardown must settle
// exactly once however many times release/save/discard race into it — the
// reentrant close/save and stale-callback regressions behind the Build 228
// exit interlock. No simulator, engine or native host is required.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

@Suite("FloeApp.OfficeEditEntryAck")
@MainActor
struct OfficeEditEntryAckTests {

    @Test("A resolution that lands before the wait is replayed verbatim")
    func resolveBeforeWait() async {
        let ack = OfficeEditEntryAck()
        ack.resolve((false, true))
        let result = await ack.wait()
        #expect(result.readOnly == false)
        #expect(result.pendingPassword == true)
    }

    @Test("A resolution after the wait resumes the waiter once")
    func resolveAfterWait() async {
        let ack = OfficeEditEntryAck()
        async let result = ack.wait()
        ack.resolve((false, false))
        let value = await result
        #expect(value.readOnly == false)
        #expect(value.pendingPassword == false)
    }

    @Test("The first resolver wins; a late host callback can never resume twice")
    func firstResolverWins() async {
        let ack = OfficeEditEntryAck()
        ack.resolve((true, false))
        // A late native completion (or the timeout) must be ignored.
        ack.resolve((false, false))
        let result = await ack.wait()
        #expect(result.readOnly == true)
        #expect(result.pendingPassword == false)
    }

    @Test("The timeout resolution unblocks the acknowledgement as unverified read-only")
    func timeoutUnblocksAsReadOnly() async {
        let ack = OfficeEditEntryAck()
        async let result = ack.wait()
        // The bounded wait's timeout resolver.
        ack.resolve((true, false))
        let value = await result
        #expect(value.readOnly == true)
        #expect(value.pendingPassword == false)
    }
}

@Suite("FloeApp.OfficeSaveReceipt")
@MainActor
struct OfficeSaveReceiptTests {

    @Test("A success settled before the wait is replayed to every late waiter")
    func settledSuccessIsReplayed() async throws {
        let receipt = OfficeSaveReceipt()
        receipt.resolve(.success(()))
        try await receipt.wait()
        try await receipt.wait()
    }

    @Test("A failure settled before the wait keeps failing every late waiter — never a fabricated success")
    func settledFailureIsReplayedVerbatim() async {
        let receipt = OfficeSaveReceipt()
        receipt.resolve(.failure(NSError(domain: "org.floeagent.tests", code: 1)))
        for _ in 0..<2 {
            do {
                try await receipt.wait()
                Issue.record("a settled save failure must keep failing late waits")
            } catch {
                #expect((error as NSError).code == 1)
            }
        }
    }

    @Test("The first resolver wins; a stale engine receipt landing after the timeout never resumes twice")
    func firstResolverWins() async {
        let receipt = OfficeSaveReceipt()
        async let wait = receipt.wait()
        receipt.resolve(.failure(NSError(domain: "org.floeagent.tests", code: 8)))
        receipt.resolve(.success(()))
        do {
            try await wait
            Issue.record("the first (timeout) resolver must win over the stale receipt")
        } catch {
            #expect((error as NSError).code == 8)
        }
    }
}

@Suite("FloeApp.OfficeSessionExit")
@MainActor
struct OfficeSessionExitTests {

    @Test("A save on a session that never opened is refused cleanly: no error claim, no phase change")
    func saveWithoutOpenIsRefusedCleanly() async {
        let session = OfficeFileSession()
        let saved = await session.saveAndReturn()
        #expect(!saved)
        #expect(session.error == nil, "a policy refusal is not a save failure and must not surface an error")
        #expect(session.phase == .idle)
        let kept = await session.keepChangesAndReturn()
        #expect(!kept)
        #expect(session.phase == .idle)
    }

    @Test("Concurrent edit intents on a never-opened session all complete exactly once")
    func concurrentEditIntentsCompleteOnce() async {
        let session = OfficeFileSession()
        async let first = session.requestEditing()
        async let second = session.requestEditing()
        async let third = session.requestEditing()
        // No edit intent may hang or be dropped, whatever order the queued
        // intent replays behind the owning operation.
        _ = await (first, second, third)
        #expect(session.phase == .idle)
    }

    @Test("Reentrant release settles exactly once and never hangs")
    func reentrantReleaseSettlesOnce() async {
        let session = OfficeFileSession()
        async let first = session.release()
        async let second = session.release()
        _ = await (first, second)
        #expect(session.phase == .idle)
        // A later release (a second disappear/teardown) is a harmless no-op.
        await session.release()
        #expect(session.phase == .idle)
    }

    @Test("A pre-mount open failure is recoverable: the loader re-arms instead of dead-ending")
    func preMountFailureRecoveryRearmsLoader() async {
        let session = OfficeFileSession()
        session.reportOpenFailure(NSError(domain: "org.floeagent.tests", code: 2))
        #expect(session.phase == .failed)
        #expect(session.canRecoverFailedSession)
        let recovered = await session.recoverFailedSession()
        #expect(recovered)
        #expect(session.phase == .idle)
        #expect(session.error == nil)
    }
}

@Suite("FloeApp.OfficeOpenGeneration")
@MainActor
struct OfficeOpenGenerationTests {

    @Test("The generation advances monotonically per mounted open")
    func advancesMonotonically() {
        var generation = OfficeOpenGeneration()
        #expect(generation.current == 0)
        #expect(generation.advance() == 1)
        #expect(generation.advance() == 2)
        #expect(generation.current == 2)
    }

    @Test("A callback from an older generation can never settle the current session")
    func staleGenerationIsRejected() {
        var generation = OfficeOpenGeneration()
        let preview = generation.advance()
        #expect(generation.isCurrent(preview))
        // The preview-to-edit switch mounts a new controller: the generation
        // the preview's callbacks captured is stale from here on.
        let editing = generation.advance()
        #expect(generation.isCurrent(editing))
        #expect(!generation.isCurrent(preview), "a stale callback must not settle the new session")
        // A late render/permission report from the preview's controller is
        // ignored even though it arrives after the edit mount.
        #expect(!generation.isCurrent(preview))
        #expect(generation.isCurrent(editing))
    }

    @Test("Generation zero is never current once the first open advanced")
    func zeroIsNeverCurrentAfterFirstAdvance() {
        var generation = OfficeOpenGeneration()
        #expect(generation.isCurrent(0), "before any open, generation zero is the current one")
        _ = generation.advance()
        #expect(!generation.isCurrent(0))
    }
}
#endif
