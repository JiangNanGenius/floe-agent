// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct PrintProgress: Sendable {
    public let identity: PrintRequestIdentity
    public let stage: String
    public let fraction: Double
    public init(identity: PrintRequestIdentity, stage: String, fraction: Double) {
        self.identity = identity; self.stage = stage
        self.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
    }
}

/// Mainline supplies an owned native compute adapter. Never expose a general script interpreter.
public protocol PrintSlicingBackend: Sendable {
    func slice(_ request: PrintRequest, progress: @escaping @Sendable (PrintProgress) async -> Void) async throws -> Data
    /// Must stop/retire its owned computation. Service holds its slot until slice unwinds.
    func cancel(jobID: UUID) async
}

/// One mutable engine per service; independent of SwiftUI view lifetime or editor undo state.
public actor PrintSlicingService {
    private let backend: any PrintSlicingBackend
    private var active: (identity: PrintRequestIdentity, generation: UUID, cancelled: Bool)?

    public init(backend: any PrintSlicingBackend) { self.backend = backend }

    public func slice(_ request: PrintRequest, progress: @escaping @Sendable (PrintProgress) async -> Void = { _ in }) async throws -> PrintArtifact {
        guard active == nil else { throw PrintError.busy }
        try Task.checkCancellation()
        let generation = UUID()
        active = (request.identity, generation, false)
        defer { if active?.generation == generation { active = nil } }
        return try await withTaskCancellationHandler {
            let data = try await backend.slice(request) { [weak self] update in
                guard let self, await self.accepts(update.identity, generation: generation) else { return }
                await progress(update)
            }
            try Task.checkCancellation()
            guard accepts(request.identity, generation: generation) else { throw PrintError.cancelled }
            return try PrintArtifact(request: request, data: data)
        } onCancel: {
            Task { await self.cancelGeneration(request.identity, generation: generation) }
        }
    }

    public func cancel(jobID: UUID) async {
        guard var current = active, current.identity.jobID == jobID else { return }
        current.cancelled = true; active = current
        await backend.cancel(jobID: jobID)
    }

    private func cancelGeneration(_ identity: PrintRequestIdentity, generation: UUID) async {
        guard active?.generation == generation, active?.identity == identity else { return }
        await cancel(jobID: identity.jobID)
    }

    private func accepts(_ identity: PrintRequestIdentity, generation: UUID) -> Bool {
        guard let active else { return false }
        return !active.cancelled && active.generation == generation && active.identity == identity
    }
}
