// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameBuildKit

final class GameBuildProvenanceBindingTests: XCTestCase {
    private func provenance(jobID: String = "42",
                            schema: Int = 2,
                            source: String = String(repeating: "a", count: 64),
                            revision: String = "rev-1",
                            engine: String = "phaser",
                            template: String = "floe-game-build-script-web",
                            transport: String = "repository",
                            selectionSchema: Int = 0,
                            gameRoot: String = "",
                            selected: String = "") -> GameBuildProvenance {
        GameBuildProvenance(
            sourceSHA256: source, sourceRevision: revision, engine: engine,
            template: template, sourceTransport: transport,
            artifacts: ["phaser-web.zip": .init(
                sha256: String(repeating: "b", count: 64), bytes: 12)],
            targets: ["web"], artifactPrefix: "phaser",
            selectionSchemaVersion: selectionSchema, gameRoot: gameRoot,
            selectedSourceSHA256: selected, jobID: jobID,
            schemaVersion: schema)
    }

    func testSchemaTwoRequiresTheExactDispatchedJobIdentity() throws {
        let value = provenance()
        XCTAssertNoThrow(try value.verifyJob(jobID: "42"))
        XCTAssertThrowsError(try value.verifyJob(jobID: "43"))
    }

    func testSchemaOneWithoutJobIdentityRemainsReadableButIsNotJobBound() throws {
        let legacy = provenance(jobID: "", schema: 1, selectionSchema: 1,
                                gameRoot: "games/a",
                                selected: String(repeating: "c", count: 64))
        XCTAssertNoThrow(try legacy.verify(
            sourceDigest: String(repeating: "a", count: 64),
            revision: "rev-1", engine: "phaser",
            gameRoot: "games/a",
            selectedSourceDigest: String(repeating: "c", count: 64)))
        // Schema-1 provenance predates job identity. It remains readable for a
        // matching nested selection but carries no run-id attestation; new
        // templates must emit schema 2 and are checked exactly.
        XCTAssertNoThrow(try legacy.verifyJob(jobID: "42"))
        let legacyProject = provenance(jobID: "", schema: 1,
                                       selectionSchema: 0)
        XCTAssertThrowsError(try legacyProject.verify(
            sourceDigest: String(repeating: "a", count: 64),
            revision: "rev-1", engine: "phaser",
            gameRoot: "games/a",
            selectedSourceDigest: String(repeating: "c", count: 64)))
    }

    func testSelectionDigestAndTransportMustMatch() throws {
        let value = provenance(selectionSchema: 1, gameRoot: "games/a",
                               selected: String(repeating: "c", count: 64))
        XCTAssertNoThrow(try value.verifySelection(
            gameRoot: "games/a",
            selectedSourceDigest: String(repeating: "c", count: 64)))
        XCTAssertThrowsError(try value.verifySelection(
            gameRoot: "games/b",
            selectedSourceDigest: String(repeating: "c", count: 64)))
        XCTAssertThrowsError(try value.verifySourceTransport("artifact"))
        XCTAssertNoThrow(try value.verifyTemplate("floe-game-build-script-web"))
        XCTAssertThrowsError(try value.verifyTemplate("floe-game-build-unity"))
    }

    func testCanonicalWholeProjectDigestMatchesTheReviewedExecutableRows() async throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        let repository = try FileGameProjectRepository(
            directory: fixture.root.appendingPathComponent("repo"))
        let id = UUID(), owner = GameProjectOwner.space(recordID: id)
        let created = try await repository.createProject(
            projectID: id, owner: owner, title: "Digest", engine: .phaser)
        _ = try await repository.importContents(
            from: fixture.project(), into: id, owner: owner,
            expectedRevision: created.revision)
        let stored = try await repository.open(id, owner: owner)
        let expected = GameDigest.sha256(Data(stored.files.map {
            "\($0.path.value):\($0.sha256):\($0.bytes):\($0.executable ? "1" : "0")"
        }.sorted().joined(separator: "\n").utf8))
        XCTAssertEqual(GameBuildCoordinator.sourceDigest(of: stored), expected)
    }

    func testWorkflowTemplatesEchoSchemaTwoAndTheRunId() throws {
        for template in try GameCIWorkflowTemplates.all() {
            XCTAssertTrue(template.yaml.contains("\\\"schemaVersion\\\": 2"), template.id)
            XCTAssertTrue(template.yaml.contains("\\\"jobID\\\": os.environ.get(\\\"GITHUB_RUN_ID\\\", \\\"\\\")"),
                          template.id)
            XCTAssertNoThrow(try GameCIWorkflowTemplates.validate(template))
        }
    }
}
