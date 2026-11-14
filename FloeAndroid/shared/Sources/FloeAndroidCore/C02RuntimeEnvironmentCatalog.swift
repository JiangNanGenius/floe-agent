// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeAndroidShellTools

/// Read-only metadata from the authenticated runtime peer. No cached schedule
/// snapshot, synthetic environment or cross-project fallback is used here.
///
/// Every failure is a TYPED `C02ExecutionTargetError`:
///  * `rootEpochUnavailable` when the native generation moved, and
///  * `environmentCatalogUnavailable(reason)` when the bounded host/runtime
///    read could not produce a catalog.
/// The previous implementation let `LinuxShellTransportError` and
/// `DecodingError` escape, which the trusted target bridge reported as the
/// generic `internalFailure` ("The execution target operation failed.") and
/// the ordinary run assembly silently collapsed to "no Linux target". The
/// catalog classifies every read; the RUN assembly performs the ONE bounded
/// retry of a fast transient so a generation that is still settling right
/// after the first-use preflight is not turned into a permanent "no Linux".
/// Nothing here fabricates rows, substitutes another project or widens
/// ownership, and a real timeout is never retried.
public enum C02RuntimeEnvironmentCatalog {
    public struct Row: Decodable, Sendable {
        public let id: String
        public let kind: String
        public let ownerID: String?
        public let name: String?
        public let state: String
        public let baseRevision: String
        public let requiresRebuild: Bool
        public let executionBackend: String?
        public let parentID: String?
        public let layerFormat: Int?

        public func targetFacts(projectOwner: String) -> C02LocalEnvironmentFacts {
            C02LocalEnvironmentFacts(id: id, name: name, kind: kind, state: state,
                requiresRebuild: requiresRebuild, executionBackend: executionBackend,
                ownerID: kind == "project" ? projectOwner : ownerID)
        }
    }
    private struct Envelope: Decodable {
        let phase: String
        let code: String?
        let projectID: UUID?
        let workspaceOwnerID: String?
        let environments: [Row]?
    }

    public static func read(ownership: C02TargetOwnership) async throws -> [Row] {
        try await read(workspaceRoot: ownership.workspaceRoot,
                       epoch: ownership.rootEpoch)
    }

    /// ONE bounded read. The run assembly owns the single retry of a FAST
    /// transient (see `FacadeRunDomain.linuxRoute`), so this function never
    /// nests a second mailbox wait inside the caller's budget.
    public static func read(workspaceRoot: URL, epoch: UInt64) async throws -> [Row] {
        guard epoch > 0,
              G02NativeRootEpoch.readback() == epoch else {
            throw C02ExecutionTargetError.rootEpochUnavailable
        }
        let projectID = LinuxShellProjectMapping.projectID(
            forCanonicalCoreWorkspaceRoot: workspaceRoot)
        let payload = try JSONSerialization.data(withJSONObject: [
            "action": "catalog", "epoch": epoch,
            "projectID": projectID.uuidString
        ], options: [.sortedKeys])
        let bytes: Data
        do {
            bytes = try await LinuxShellMailbox.shared.submit(
                operation: C01LinuxEnvironmentMailboxHost.operation,
                payload: payload, timeoutMillis: 18_000)
        } catch let error as C02ExecutionTargetError {
            throw error
        } catch let error as LinuxShellTransportError {
            throw C02ExecutionTargetError.environmentCatalogUnavailable(Self.reason(error))
        } catch is CancellationError {
            throw C02ExecutionTargetError.environmentCatalogUnavailable("cancelled")
        } catch {
            throw C02ExecutionTargetError.environmentCatalogUnavailable("unreadable")
        }
        guard bytes.count <= 65_536,
              G02NativeRootEpoch.readback() == epoch else {
            throw C02ExecutionTargetError.rootEpochUnavailable
        }
        return try decodeEnvelope(bytes, projectID: projectID)
    }

    /// Closed, secret-free reason vocabulary for the typed refusal.
    static func reason(_ error: LinuxShellTransportError) -> String {
        switch error {
        case .notBound: return "transportUnbound"
        case .saturated: return "transportBusy"
        case .payloadTooLarge: return "requestTooLarge"
        case .remoteFailed(let code): return Self.reasonToken(code)
        case .remoteFailedWithRestore(let code, _): return Self.reasonToken(code)
        case .remoteFailedWithStartFailure(let code, _, _, _): return Self.reasonToken(code)
        case .replyMalformed: return "replyMalformed"
        case .hostFenced: return "hostFenced"
        case .waitBudgetExpired: return "timeout"
        }
    }

    private static func reasonToken(_ code: String) -> String {
        guard !code.isEmpty, code.utf8.count <= 48,
              code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else { return "hostRefused" }
        return code
    }

    /// Accepts BOTH the strict ready reply and a typed non-ready refusal from
    /// the host (`{phase:"unavailable"|"refused", code}`). A refusal is a real
    /// typed answer, never a decode failure, and an untrusted code string can
    /// never carry a path or host prose into the error/run context.
    static func decodeEnvelope(_ bytes: Data, projectID: UUID) throws -> [Row] {
        guard bytes.count <= 65_536 else {
            throw C02ExecutionTargetError.environmentCatalogUnavailable("replyTooLarge")
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        } catch {
            throw C02ExecutionTargetError.environmentCatalogUnavailable("replyUnreadable")
        }
        guard envelope.phase == "ready" else {
            throw C02ExecutionTargetError.environmentCatalogUnavailable(
                Self.reasonToken(envelope.code ?? "hostRefused"))
        }
        guard envelope.projectID == projectID,
              let owner = envelope.workspaceOwnerID,
              owner.count == 64, owner.allSatisfy({ $0.isHexDigit }),
              let rows = envelope.environments, rows.count <= 2048 else {
            throw C02ExecutionTargetError.environmentCatalogUnavailable("hostShapeMismatch")
        }
        let projects = rows.filter { $0.kind == "project" }
        let ids = Set(rows.map(\.id))
        guard projects.count <= 1, ids.count == rows.count,
              projects.allSatisfy({ $0.ownerID == owner }),
              rows.allSatisfy({ row in
                  !row.id.isEmpty && row.id.utf8.count <= 128 &&
                  (row.kind == "project" || (row.kind == "session" &&
                   row.parentID == projects.first?.id && !projects.isEmpty))
              }) else {
            throw C02ExecutionTargetError.environmentCatalogUnavailable("hostShapeMismatch")
        }
        return rows
    }

    static func decode(_ bytes: Data, projectID: UUID) throws -> [Row] {
        guard bytes.count <= 65_536 else {
            throw C02ExecutionTargetError.environmentUnavailable("catalog")
        }
        do {
            return try decodeEnvelope(bytes, projectID: projectID)
        } catch let error as C02ExecutionTargetError {
            if case .environmentCatalogUnavailable(let reason) = error,
               reason == "hostShapeMismatch" || reason == "replyUnreadable" {
                throw C02ExecutionTargetError.environmentUnavailable("catalog")
            }
            throw error
        }
    }
}
