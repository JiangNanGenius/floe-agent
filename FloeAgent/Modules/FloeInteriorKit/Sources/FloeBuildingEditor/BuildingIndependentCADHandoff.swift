// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import FloeCAD
import FloeBuildingCAD
import FloeBuildingRecords

public enum BuildingIndependentCADKind: String, Codable, Sendable, Hashable {
    case twoD, threeD
}

/// A verified exported package for the host's existing Space project service.
/// The host copies it into its own storage and validates the copied identity;
/// it must never register the building working-copy URL as mutable shared data.
/// The host owns durable deduplication using `idempotencyKey` in its target Space.
public struct BuildingIndependentCADHandoff: Sendable {
    public let kind: BuildingIndependentCADKind
    public let sourceProjectID: ProjectID
    public let deliveryID: UUID
    public let title: String
    public let relativePath: String
    public let packageURL: URL
    public let packageIdentity: FloeBuildingCADNativeIdentity
    public let sourceIdentity: FloeBuildingCADNativeIdentity
    public let losses: [String]

    /// Stable across working-copy replacement and reopening the building.
    /// Absolute paths and transient mount IDs never participate.
    public var idempotencyKey: String {
        [sourceProjectID.description, deliveryID.uuidString.lowercased(), relativePath,
         packageIdentity.contentSHA256.lowercased()].joined(separator: "|")
    }

    /// Materialize the same verified export in a new owner's staging directory.
    @MainActor public func copyPackage(to destination: URL) async throws {
        try await BuildingEditorProjectSession.importNativeDocumentPackage(
            from: packageURL,
            expected: (packageIdentity.revision, packageIdentity.contentSHA256, packageIdentity.modelSHA256),
            to: destination
        )
    }

    static func kind(for file: FloeBuildingCADExportFile) -> BuildingIndependentCADKind? {
        guard file.format == "floecad-package", file.verified else { return nil }
        switch file.role {
        case "native-2d", "whole-project-native-2d": return .twoD
        case "native-3d", "whole-project-native-3d", "native-copy": return .threeD
        default: return nil
        }
    }

    @MainActor
    static func prepare(record: BuildingDeliveryRecord, file: FloeBuildingCADExportFile,
                        projectID: ProjectID) async throws -> Self {
        guard record.receipt.files.contains(file), let kind = kind(for: file),
              let url = record.fileURL(file),
              let stored = await FloeCADDocument.storedIdentity(at: url),
              stored.contentSHA256 == file.sha256,
              let modelHash = stored.modelSHA256, !modelHash.isEmpty else {
            throw BuildingProjectStateError.identityOrSchema
        }
        try Task.checkCancellation()
        return Self(kind: kind, sourceProjectID: projectID, deliveryID: record.id,
                    title: record.receipt.pageTitle, relativePath: file.relativePath,
                    packageURL: url,
                    packageIdentity: .init(revision: stored.revision,
                                           contentSHA256: stored.contentSHA256,
                                           modelSHA256: modelHash),
                    sourceIdentity: record.receipt.sourceIdentity,
                    losses: file.unsupportedLosses)
    }
}
#endif
