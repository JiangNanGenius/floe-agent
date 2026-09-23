// FloeAppTests — the bounded edit-entry acknowledgement.
//
// The Build 223 PPT edit stall could wedge a session for good when the native
// host's edit-entry completion was lost: the edit acknowledgement suspended
// forever, `operating` never cleared, and every later recovery was refused.
// `OfficeEditEntryAck` bounds that wait — the first resolver (host callback or
// timeout) wins, and a timeout reads as unverified-read-only so the session's
// re-probe and fallback decide from the engine's real state. These tests pin
// the one-shot semantics the bounded edit path relies on.

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
