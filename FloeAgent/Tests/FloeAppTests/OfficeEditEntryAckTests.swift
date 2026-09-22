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
#endif
