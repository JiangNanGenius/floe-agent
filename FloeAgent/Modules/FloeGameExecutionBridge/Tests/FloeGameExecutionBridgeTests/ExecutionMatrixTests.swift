// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
import FloeGameBuildKit
@testable import FloeGameExecutionBridge

@Suite("20-engine execution matrix")
struct ExecutionMatrixTests {
    @Test("matrix covers exactly the catalog's 20 engines and route artifacts")
    func matrixMatchesCatalog() throws {
        let document = try GameEngineExecutionMatrix.load()
        #expect(document.engineCount == 20)
        #expect(document.entries.count == 20)
        #expect(Set(document.entries.map(\.engine)) == Set(GameEngineID.authoringEngines))
        let catalog = try GameBuildCapabilityRegistry.catalog()
        for entry in document.entries {
            let catalogEntry = try #require(catalog.engines.first { $0.engine == entry.engine })
            #expect(entry.buildRoutes.map(\.id).sorted() == catalogEntry.routes.map(\.id).sorted())
            #expect(entry.requiredArtifacts == catalogEntry.routes
                .filter { $0.kind != .sourceArchive }
                .map(\.artifactName))
            if entry.runMode == .externalBuild {
                #expect(entry.externalKind != nil)
            }
            if entry.unexecutedExternalBuild {
                #expect(entry.testEvidence.contains("not executed"))
            }
        }
    }

    @Test("external kinds map to a concrete executor or a licensed prerequisite")
    func externalKindsHaveExecutors() throws {
        let document = try GameEngineExecutionMatrix.load()
        let external = document.entries.filter { $0.runMode == .externalBuild }
        #expect(!external.isEmpty)
        for entry in external {
            guard let kind = entry.externalKind else {
                Issue.record("external entry has no kind: \(entry.engine.rawValue)")
                continue
            }
            switch kind {
            case "godotWeb":
                #expect(entry.executor == .mainLinuxShell)
            case "unityWebGL", "cocosWeb", "webBundle":
                #expect(entry.executor == .githubCI)
            case "gdevelopWeb":
                #expect(entry.executor == .githubCI || entry.executor == .hostExporter)
            case "rpgMakerMZWeb", "rpgMakerMVDeployment":
                #expect(entry.executor == .userEditor)
            default:
                Issue.record("unmapped external kind \(kind)")
            }
        }
    }

    @Test("every build route names an artifact and a non-empty executor")
    func buildRoutesAreConcrete() throws {
        let document = try GameEngineExecutionMatrix.load()
        for entry in document.entries {
            for route in entry.buildRoutes {
                #expect(!route.artifactName.isEmpty)
                if route.kind == "sourceArchive" {
                    #expect(route.executor == .onDevice)
                }
            }
        }
    }
}
