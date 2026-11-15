// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameStarterKit
@testable import FloeGameProjectFlow

private actor FixtureCapabilityProbe: GameProjectSelectionCapabilityProbe {
    let reportsByEngine: [GameEngineID: [GameProjectHostPrerequisiteReport]]

    init(reportsByEngine: [GameEngineID: [GameProjectHostPrerequisiteReport]]) {
        self.reportsByEngine = reportsByEngine
    }

    func reports(engines: [GameEngineID], context: GameProjectContext) async throws
        -> [GameEngineID: [GameProjectHostPrerequisiteReport]] {
        var result: [GameEngineID: [GameProjectHostPrerequisiteReport]] = [:]
        for engine in engines {
            if let reports = reportsByEngine[engine] { result[engine] = reports }
        }
        return result
    }
}

private struct ThrowingCapabilityProbe: GameProjectSelectionCapabilityProbe {
    struct Failure: Error {}

    func reports(engines: [GameEngineID], context: GameProjectContext) async throws
        -> [GameEngineID: [GameProjectHostPrerequisiteReport]] {
        throw Failure()
    }
}

final class SelectionCapabilityTests: XCTestCase {
    private func phaserAndGodotFiles() -> [String: Data] {
        [
            "project.godot": Data("config_version=5\n".utf8),
            "package.json": Data(
                "{\"dependencies\":{\"phaser\":\"3.90.0\"}}".utf8)
        ]
    }

    func testHostProbeIsAttributedAndNeverClaimsInstalled() async throws {
        let catalog = try GameStarterCatalog.bundled()
        let descriptor = try catalog.descriptor(for: .phaser)
        let prerequisite = try XCTUnwrap(descriptor.prerequisites.first)
        let report = GameProjectHostPrerequisiteReport(
            engine: .phaser, kind: prerequisite.kind, name: prerequisite.name,
            isAvailable: false, detail: "fixture says missing",
            provider: "fixture.toolchain")
        let probe = FixtureCapabilityProbe(
            reportsByEngine: [.phaser: [report]])
        try await withSelectionWorkspace(capabilityProbe: probe) { workspace in
            let result = try await workspace.importFiles(phaserAndGodotFiles())
            XCTAssertEqual(result.snapshot.state, .ambiguous)
            let capability = try XCTUnwrap(
                result.snapshot.engines(forRoot: nil)
                    .first { $0.engine == .phaser })
            let state = try XCTUnwrap(capability.prerequisites.first {
                $0.kind == prerequisite.kind && $0.name == prerequisite.name
            })
            guard case .reported(let available, let detail, let provider) = state.host else {
                XCTFail("host report was not retained"); return
            }
            XCTAssertFalse(available)
            XCTAssertEqual(detail, "fixture says missing")
            XCTAssertEqual(provider, "fixture.toolchain")
            XCTAssertTrue(capability.prerequisites
                .filter { $0.name != prerequisite.name || $0.kind != prerequisite.kind }
                .allSatisfy { state in
                    if case .unverified = state.host { return true }
                    return false
                })

            let creation = try workspace.coordinator.creationCapabilities()
            XCTAssertTrue(creation.allSatisfy { capability in
                capability.prerequisites.allSatisfy { state in
                    if case .unverified = state.host { return true }
                    return false
                }
            }, "catalog-only creation view must not borrow a project probe")
        }
    }

    func testProbeFailureIsADiagnosticAndDoesNotBlockDiscovery() async throws {
        try await withSelectionWorkspace(
            capabilityProbe: ThrowingCapabilityProbe()
        ) { workspace in
            let result = try await workspace.importFiles(phaserAndGodotFiles())
            XCTAssertEqual(result.snapshot.state, .ambiguous)
            XCTAssertTrue(result.snapshot.diagnostics.contains {
                $0.source == .capabilityProbe
            })
            XCTAssertEqual(result.snapshot.engines(forRoot: nil).count, 2)
        }
    }

    func testInvalidAIRecommendationCannotSelectAnUnrecognizedEngine() async throws {
        let recommender: GameProjectSelectionRecommendationHandler = { _ in
            GameProjectAIEngineRecommendation(
                engine: .unity, root: nil,
                rationale: "fixture invalid suggestion",
                generatedBy: "fixture-model")
        }
        try await withSelectionWorkspace(recommender: recommender) { workspace in
            let result = try await workspace.importFiles([
                "package.json": Data(
                    "{\"dependencies\":{\"phaser\":\"3.90.0\"}}".utf8)
            ])
            XCTAssertNil(result.snapshot.aiRecommendation)
            XCTAssertEqual(result.snapshot.selectedEngine, .phaser)
            XCTAssertEqual(result.snapshot.state, .automatic)
            XCTAssertTrue(result.snapshot.diagnostics.contains {
                $0.source == .recommendation
            })
        }
    }

    func testEmptyProjectAIRecommendationIsAdvisoryForCreation() async throws {
        let recommender: GameProjectSelectionRecommendationHandler = { _ in
            GameProjectAIEngineRecommendation(
                engine: .godot, root: nil,
                rationale: "fixture suggests a creation engine",
                generatedBy: "fixture-model")
        }
        try await withSelectionWorkspace(recommender: recommender) { workspace in
            let created = try await workspace.createEmpty()
            let snapshot = try await workspace.coordinator.refresh(
                project: created.0, context: created.1)
            XCTAssertEqual(snapshot.state, .empty)
            XCTAssertEqual(snapshot.aiRecommendation?.engine, .godot)
            XCTAssertNil(snapshot.selectedEngine)
            let record = try await workspace.storedRecord(context: created.1)
            XCTAssertNil(record)
        }
    }
}
