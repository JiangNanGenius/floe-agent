import Foundation

/// Pending trust is scoped to one local attempt. A reply from a cancelled
/// attempt cannot populate a later attempt or become a persisted server pin.
public struct BridgePairingSession: Sendable {
    public struct Attempt: Equatable, Sendable {
        public let id: UUID
        public let nonce: String
    }

    public private(set) var attempt: Attempt?
    public private(set) var candidateKey: Data?
    public private(set) var approved = false

    public init() {}

    public mutating func begin() -> Attempt {
        if let attempt { return attempt }
        let value = Attempt(id: UUID(), nonce: UUID().uuidString + UUID().uuidString)
        attempt = value
        return value
    }

    public mutating func accept(
        _ pending: Attempt, nonce: String?, serverKey: Data, approved: Bool
    ) throws {
        try Task.checkCancellation()
        guard attempt == pending else { throw CancellationError() }
        guard nonce == pending.nonce,
              candidateKey == nil || candidateKey == serverKey else {
            throw BridgeFailure.authentication
        }
        candidateKey = serverKey
        self.approved = approved
    }

    public func verification(clientKey: Data) -> String? {
        guard let attempt, let candidateKey else { return nil }
        return BridgeWire.pairingVerification(
            clientKey: clientKey, serverKey: candidateKey, nonce: attempt.nonce)
    }

    public func approvedKey(clientKey: Data, verification: String) throws -> Data {
        try Task.checkCancellation()
        guard approved, let candidateKey,
              verification == self.verification(clientKey: clientKey) else {
            throw BridgeFailure.authentication
        }
        return candidateKey
    }

    public mutating func cancel() {
        attempt = nil
        candidateKey = nil
        approved = false
    }
}
