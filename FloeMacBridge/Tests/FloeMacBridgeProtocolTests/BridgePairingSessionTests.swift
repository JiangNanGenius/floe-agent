import Foundation
import Testing
@testable import FloeMacBridgeProtocol

@Suite("Mac Bridge pairing attempt ownership")
struct BridgePairingSessionTests {
    @Test("A cancelled response cannot revive trust or replace a newer attempt")
    func cancelledResponse() throws {
        var session = BridgePairingSession()
        let old = session.begin()
        session.cancel()
        let current = session.begin()
        #expect(old != current)
        #expect(throws: CancellationError.self) {
            try session.accept(old, nonce: old.nonce, serverKey: Data([1]), approved: true)
        }
        #expect(session.attempt == current)
        #expect(session.candidateKey == nil)
        #expect(!session.approved)
        try session.accept(current, nonce: current.nonce, serverKey: Data([2]), approved: true)
        let code = try #require(session.verification(clientKey: Data([3])))
        #expect(try session.approvedKey(clientKey: Data([3]), verification: code) == Data([2]))
        session.cancel()
        #expect(throws: BridgeFailure.self) {
            try session.approvedKey(clientKey: Data([3]), verification: code)
        }
    }

    @Test("Polling preserves the nonce and requires the same companion and approval")
    func pollingAndPin() throws {
        var session = BridgePairingSession()
        let attempt = session.begin()
        #expect(session.begin() == attempt)
        try session.accept(attempt, nonce: attempt.nonce, serverKey: Data([1]), approved: false)
        let code = try #require(session.verification(clientKey: Data([2])))
        #expect(throws: BridgeFailure.self) {
            try session.approvedKey(clientKey: Data([2]), verification: code)
        }
        #expect(throws: BridgeFailure.self) {
            try session.accept(attempt, nonce: attempt.nonce, serverKey: Data([9]), approved: true)
        }
        #expect(throws: BridgeFailure.self) {
            try session.accept(attempt, nonce: "different", serverKey: Data([1]), approved: true)
        }
        #expect(!session.approved)
        try session.accept(attempt, nonce: attempt.nonce, serverKey: Data([1]), approved: true)
        #expect(throws: BridgeFailure.self) {
            try session.approvedKey(clientKey: Data([2]), verification: "wrong")
        }
        #expect(try session.approvedKey(clientKey: Data([2]), verification: code) == Data([1]))
    }
}
