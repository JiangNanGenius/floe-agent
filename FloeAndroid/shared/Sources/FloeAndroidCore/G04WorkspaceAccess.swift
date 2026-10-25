// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools
import FloeWorkspace

struct G04WorkspaceOwnedOperation: Sendable {
    /// Native-issued identity of THIS operation lease (G04-R2): the trusted
    /// UI lanes register it with the workspace authority so a grant can be
    /// minted against the REAL lease instead of a persisted model Run. The
    /// ownerID's trailing component is exactly this identity, so the registry
    /// shape, attach/detach discipline and every existing consumer are
    /// unchanged; nothing else interprets it.
    let operationID: UUID
    let conversationID: UUID
    let token: RuntimeOwnedWorkToken
    let cancellation: CancellationToken
}

extension FacadeRunDomain {
    /// Same actor step as deletion/global admission fences. This is real
    /// conversation-owned work, not a fabricated model Run or P8 feed.
    func beginG04WorkspaceOperation(conversationID: UUID, expectedEpoch: UInt64)
        -> G04WorkspaceOwnedOperation? {
        guard expectedEpoch == epoch, !retirementFenced, globalFence == nil,
              deleteGuards[conversationID] == nil else { return nil }
        let operationID = UUID()
        let ownerID = conversationID.uuidString + ":workspace:" + operationID.uuidString
        guard case .attached(let token) = RuntimeOwnedWorkRegistry.shared.attach(
            epoch: epoch, kind: .conversation, ownerID: ownerID) else { return nil }
        let operation = G04WorkspaceOwnedOperation(operationID: operationID,
                                                   conversationID: conversationID, token: token,
                                                   cancellation: CancellationToken())
        workspaceOperationLeases[conversationID, default: [:]][token.receipt] = operation
        return operation
    }

    func validateG04WorkspaceOperation(_ operation: G04WorkspaceOwnedOperation) -> Bool {
        guard operation.token.epoch == epoch, !retirementFenced, globalFence == nil,
              deleteGuards[operation.conversationID] == nil,
              workspaceOperationLeases[operation.conversationID]?[operation.token.receipt]?.token == operation.token,
              RuntimeOwnedWorkRegistry.shared.isAttached(operation.token),
              !operation.cancellation.isCancelled else { return false }
        return true
    }

    func endG04WorkspaceOperation(_ operation: G04WorkspaceOwnedOperation) {
        guard workspaceOperationLeases[operation.conversationID]?[operation.token.receipt]?.token == operation.token
        else { return }
        RuntimeOwnedWorkRegistry.shared.detach(operation.token)
        workspaceOperationLeases[operation.conversationID]?.removeValue(forKey: operation.token.receipt)
        if workspaceOperationLeases[operation.conversationID]?.isEmpty == true {
            workspaceOperationLeases[operation.conversationID] = nil
        }
    }

    func cancelG04WorkspaceOperations(conversationID: UUID? = nil) {
        for (owner, operations) in workspaceOperationLeases {
            guard conversationID == nil || conversationID == owner else { continue }
            for operation in operations.values { operation.cancellation.cancel() }
        }
        // Cancellation is a request. Tokens remain attached until the
        // actual operation releases them, including failed IO paths.
    }

    func g04WorkspaceDrainEvidenceCount(conversationID: UUID) -> Int {
        workspaceDrainEvidence[conversationID]?.count ?? 0
    }
}

/// Live access over the SAME accepted store cluster and Run-owned deletion
/// fences. Authorizer and resolver are supplied by trusted composition;
/// imported content and bridge payloads cannot install these closures.
public struct G04LiveWorkspaceAccess: G04WorkspaceAccessPort {
    public struct Target: Sendable {
        public let logicalPath: String
        public let resolvedURL: URL
    }
    public typealias Authorizer = @Sendable (G04WorkspaceOwner, G04WorkspaceIntent, Target?, CancellationToken) async throws -> Void
    public typealias Resolver = @Sendable (G04WorkspaceOwner, CancellationToken) async throws -> WorkspaceFileService
    private let epoch: UInt64
    private let authorize: Authorizer
    private let resolve: Resolver

    public init(epoch: UInt64, authorize: @escaping Authorizer, resolve: @escaping Resolver) {
        self.epoch = epoch; self.authorize = authorize; self.resolve = resolve
    }

    public func acquire(owner: G04WorkspaceOwner, intent: G04WorkspaceIntent,
                        relativePath: String?) async throws -> G04WorkspaceAccessLease {
        guard epoch == owner.epoch, G02NativeRootEpoch.readback() == epoch,
              let installed = G02RuntimeComposition.shared.installedComposition, installed.epoch == epoch,
              let (domain, _) = RunDomainFacade.current(epoch: epoch),
              let operation = await domain.beginG04WorkspaceOperation(conversationID: owner.taskID,
                                                                       expectedEpoch: epoch)
        else { throw G04DocumentError.retired }
        do {
            try operation.cancellation.throwIfCancelled()
            guard try await installed.cluster.conversationStore.conversation(id: owner.taskID) != nil,
                  try await installed.cluster.workspaceStore.workspaceID(conversationID: owner.taskID) == owner.workspaceID
            else { throw G04DocumentError.ownerChanged }
            try operation.cancellation.throwIfCancelled()
            let service = try await resolve(owner, operation.cancellation)
            try operation.cancellation.throwIfCancelled()
            let target = try relativePath.map {
                Target(logicalPath: ($0 as NSString).standardizingPath,
                       resolvedURL: try service.guardResolver.resolve($0))
            }
            try await authorize(owner, intent, target, operation.cancellation)
            guard G02NativeRootEpoch.readback() == epoch,
                  G02RuntimeComposition.shared.installedComposition === installed,
                  await domain.validateG04WorkspaceOperation(operation) else { throw G04DocumentError.retired }
            try operation.cancellation.throwIfCancelled()
            return G04WorkspaceAccessLease(service: service, cancellation: operation.cancellation,
                                            release: { await domain.endG04WorkspaceOperation(operation) })
        } catch {
            await domain.endG04WorkspaceOperation(operation)
            throw error
        }
    }

    /// The existing private-task path, for a caller explicitly selecting
    /// that write layer. Managed project/SAF resolvers must be wired from
    /// their ORIGINAL records; this never guesses the first project.
    public static func privateTaskService(_ owner: G04WorkspaceOwner, cancellation: CancellationToken) async throws -> WorkspaceFileService {
        try cancellation.throwIfCancelled()
        guard let binding = await LinuxWorkspaceAuthority.resolveWorkspace(conversationID: owner.taskID),
              binding.workspaceID == owner.workspaceID else { throw G04DocumentError.ownerChanged }
        try cancellation.throwIfCancelled()
        return WorkspaceFileService(guard: WorkspacePathGuard(rootURL: binding.rootURL))
    }
}
