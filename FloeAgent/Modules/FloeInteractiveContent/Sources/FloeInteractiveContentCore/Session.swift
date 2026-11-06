// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum InteractivePersistence: Sendable, Equatable { case durable, temporary }

public struct RuntimeSeed: Codable, Sendable {
    public let version: Int
    public let leaseID: UUID
    public let state: InteractiveState
    public init(leaseID: UUID, state: InteractiveState) {
        version = 1
        self.leaseID = leaseID
        self.state = state
    }
}

public struct RuntimeMessage: Codable, Sendable {
    public enum Event: String, Codable, Sendable { case ready, state, resize }
    public let version: Int
    public let leaseID: UUID
    public let sequence: UInt64
    public let event: Event
    public let expectedRevision: UInt64?
    public let modelContent: JSONValue?
    public let privateContent: JSONValue?
    public let height: Double?

    public init(leaseID: UUID, sequence: UInt64, event: Event, expectedRevision: UInt64? = nil,
                modelContent: JSONValue? = nil, privateContent: JSONValue? = nil, height: Double? = nil,
                version: Int = 1) {
        self.version = version
        self.leaseID = leaseID
        self.sequence = sequence
        self.event = event
        self.expectedRevision = expectedRevision
        self.modelContent = modelContent
        self.privateContent = privateContent
        self.height = height
    }

    private enum CodingKeys: String, CodingKey {
        case version, leaseID, sequence, event, expectedRevision, modelContent, privateContent, height
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        leaseID = try values.decode(UUID.self, forKey: .leaseID)
        sequence = try values.decode(UInt64.self, forKey: .sequence)
        event = try values.decode(Event.self, forKey: .event)
        expectedRevision = try values.decodeIfPresent(UInt64.self, forKey: .expectedRevision)
        // Explicit JSON null means clear; an absent key means an invalid partial envelope.
        modelContent = values.contains(.modelContent) ? try values.decode(JSONValue.self, forKey: .modelContent) : nil
        privateContent = values.contains(.privateContent) ? try values.decode(JSONValue.self, forKey: .privateContent) : nil
        height = try values.decodeIfPresent(Double.self, forKey: .height)
    }

    public static func decode(_ data: Data) throws -> Self {
        try InteractiveLimits.checkJSON(data, maximum: InteractiveLimits.bridgeBytes)
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

public struct RuntimeReceipt: Codable, Sendable {
    public let version: Int
    public let state: InteractiveState
    public let height: Double?
    public init(state: InteractiveState, height: Double? = nil) {
        version = 1
        self.state = state
        self.height = height
    }
}

/// Lifetime belongs to the conversation service, not a transient SwiftUI view.
/// A replacement renderer receives a fresh lease and restores the same state.
public actor InteractiveSession {
    public let document: InteractiveDocument
    public let persistence: InteractivePersistence
    private let repository: any InteractiveStateRepository
    private var leaseID = UUID()
    private var lastSequence: UInt64 = 0
    private var closed = false
    private var mutating = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(document: InteractiveDocument, expectedOwner: ContentOwner,
                persistence: InteractivePersistence, durableRepository: (any InteractiveStateRepository)? = nil) throws {
        try document.validate()
        guard document.owner == expectedOwner else { throw InteractiveError.ownershipMismatch }
        if case .durable = persistence, durableRepository == nil {
            throw InteractiveError.unsafeStorage
        }
        self.document = document
        self.persistence = persistence
        // A supplied disk store can NEVER turn a temporary session into a durable one.
        repository = persistence == .temporary
            ? MemoryInteractiveStateRepository() : durableRepository!
    }

    public func activateRenderer() async throws -> RuntimeSeed {
        try Task.checkCancellation()
        await enter()
        defer { leave() }
        try Task.checkCancellation()
        guard !closed else { throw InteractiveError.closed }
        let state = try await repository.load(document: document)
        try Task.checkCancellation()
        guard !closed else { throw InteractiveError.closed }
        leaseID = UUID()
        lastSequence = 0
        return RuntimeSeed(leaseID: leaseID, state: state)
    }

    public func receive(_ message: RuntimeMessage) async throws -> RuntimeReceipt {
        try Task.checkCancellation()
        await enter()
        defer { leave() }
        try Task.checkCancellation()
        guard !closed else { throw InteractiveError.closed }
        guard message.version == 1 else { throw InteractiveError.unsupportedVersion(message.version) }
        guard message.leaseID == leaseID else { throw InteractiveError.staleRuntime }
        guard message.sequence > lastSequence,
              message.sequence <= InteractiveLimits.maximumBridgeInteger else { throw InteractiveError.invalidSequence }
        let current = try await repository.load(document: document)
        // close() fences new work immediately, including work waiting on persistence.
        guard !closed, message.leaseID == leaseID else { throw InteractiveError.staleRuntime }
        let result: RuntimeReceipt
        switch message.event {
        case .ready: result = RuntimeReceipt(state: current)
        case .resize:
            guard let height = message.height, height.isFinite, (80...4_096).contains(height) else {
                throw InteractiveError.limitExceeded
            }
            result = RuntimeReceipt(state: current, height: height)
        case .state:
            guard let revision = message.expectedRevision,
                  let modelContent = message.modelContent, let privateContent = message.privateContent else {
                throw InteractiveError.invalidJSON
            }
            let next = try await repository.compareAndSwap(
                document: document, expectedRevision: revision,
                modelContent: modelContent, privateContent: privateContent
            )
            result = RuntimeReceipt(state: next)
        }
        lastSequence = message.sequence
        return result
    }

    public func snapshot() async throws -> InteractiveState {
        await enter()
        defer { leave() }
        guard !closed else { throw InteractiveError.closed }
        return try await repository.load(document: document)
    }

    public func close() async throws {
        closed = true
        leaseID = UUID()
        await enter()
        defer { leave() }
        if persistence == .temporary { try await repository.remove(document: document) }
    }

    private func enter() async {
        while mutating {
            await withCheckedContinuation { waiters.append($0) }
        }
        mutating = true
    }

    private func leave() {
        mutating = false
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
