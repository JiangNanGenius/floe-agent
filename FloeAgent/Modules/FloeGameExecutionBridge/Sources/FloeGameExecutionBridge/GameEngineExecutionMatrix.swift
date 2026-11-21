// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameBuildKit

/// Authoritative 20-engine closure/capability matrix. It separates:
/// * the run route (static/portable/narrative/runtime pack/external/guest);
/// * each catalog build route and its real producer;
/// * the executor this package actually binds;
/// * whether the path is implemented source, an existing adapter, a user
///   prerequisite, or an external build that has not been executed here.
public enum GameEngineExecutionMatrix {
    public struct BuildRoute: Codable, Equatable, Sendable {
        public let id: String
        public let kind: String
        public let producer: String
        public let platform: String?
        public let artifactName: String
        public let proof: String
        public let playable: Bool
        public let executor: GameExecutionExecutor
        public let note: String?
    }

    public struct Entry: Codable, Equatable, Sendable {
        public let engine: GameEngineID
        public let runMode: GameExecutionMode
        public let runRouteID: String
        public let externalKind: String?
        public let executor: GameExecutionExecutor
        public let buildRoutes: [BuildRoute]
        public let requiredArtifacts: [String]
        public let prerequisites: [String]
        public let status: String
        public let testEvidence: String
        public let unexecutedExternalBuild: Bool
        public let notes: [String]
    }

    public struct Document: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let catalogID: String
        public let engineCount: Int
        public let entries: [Entry]
        public let notes: [String]
    }

    public static func load(bundle: Bundle? = nil) throws -> Document {
        let bundle = bundle ?? .module
        let url = bundle.url(forResource: "engine-execution-matrix", withExtension: "json",
                             subdirectory: "Resources")
            ?? bundle.url(forResource: "engine-execution-matrix", withExtension: "json")
        guard let url else {
            throw GameExecutionError.invalidConfiguration("missing engine-execution-matrix.json")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let document = try JSONDecoder().decode(Document.self, from: data)
        try validate(document)
        return document
    }

    public static func entries(bundle: Bundle? = nil) throws -> [Entry] {
        try load(bundle: bundle).entries
    }

    public static func validate(_ document: Document) throws {
        guard document.schemaVersion == 1,
              document.engineCount == 20,
              document.entries.count == 20,
              Set(document.entries.map(\.engine)) == Set(GameEngineID.authoringEngines),
              Set(document.entries.map(\.engine)).count == document.entries.count else {
            throw GameExecutionError.invalidConfiguration("matrix does not cover exactly the 20 engines")
        }
        let catalog = try GameBuildCapabilityRegistry.catalog()
        guard catalog.catalogID == document.catalogID,
              catalog.engineCount == document.engineCount else {
            throw GameExecutionError.invalidConfiguration("matrix catalog identity is stale")
        }
        for entry in document.entries {
            guard let catalogEntry = catalog.engines.first(where: { $0.engine == entry.engine }) else {
                throw GameExecutionError.invalidConfiguration("matrix engine missing from catalog")
            }
            let catalogRoutes = catalogEntry.routes.map(\.id).sorted()
            let matrixRoutes = entry.buildRoutes.map(\.id).sorted()
            guard catalogRoutes == matrixRoutes else {
                throw GameExecutionError.invalidConfiguration(
                    "matrix routes for \(entry.engine.rawValue) do not match the catalog")
            }
            for route in entry.buildRoutes {
                guard let catalogRoute = catalogEntry.routes.first(where: { $0.id == route.id }),
                      catalogRoute.artifactName == route.artifactName,
                      catalogRoute.kind.rawValue == route.kind else {
                    throw GameExecutionError.invalidConfiguration(
                        "matrix route \(route.id) does not match the catalog")
                }
            }
            if entry.runMode == .externalBuild, entry.externalKind == nil {
                throw GameExecutionError.invalidConfiguration(
                    "external run route for \(entry.engine.rawValue) has no kind")
            }
            if entry.unexecutedExternalBuild {
                guard entry.testEvidence.contains("not executed") else {
                    throw GameExecutionError.invalidConfiguration(
                        "external route for \(entry.engine.rawValue) must disclose unexecuted evidence")
                }
            }
        }
    }
}
