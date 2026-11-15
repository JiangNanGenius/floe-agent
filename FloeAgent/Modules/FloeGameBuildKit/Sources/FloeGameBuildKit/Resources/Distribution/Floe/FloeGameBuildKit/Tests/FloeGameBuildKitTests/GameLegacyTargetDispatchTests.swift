// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeGameBuildKit

private actor LegacySourceCI: GameBuildCISourceJobsPort {
    private(set) var dispatched = 0
    func dispatch(template: GameCIWorkflowTemplate, sourceDigest: String,
                  revision: String, engineVersion: String?) async throws -> GameCIJobHandle {
        dispatched += 1; return .init(jobID: "legacy-digest")
    }
    func dispatch(template: GameCIWorkflowTemplate, source: GameBuildSourceTransport,
                  engineVersion: String?) async throws -> GameCIJobHandle {
        dispatched += 1; return .init(jobID: "legacy-source")
    }
    func status(_ handle: GameCIJobHandle) async throws -> GameCIJobStatus {
        .init(handle: handle, state: .running)
    }
    func artifact(_ handle: GameCIJobHandle, named: String) async throws -> Data {
        throw GameBuildError.artifactMissing(named)
    }
    func cancel(_ handle: GameCIJobHandle) async throws {}
    func verifyExistingArtifact(_ reference: GameBuildRemoteArtifactReference) async throws -> GameBuildArtifactIdentity {
        throw GameBuildError.artifactMissing(reference.name)
    }
}

final class GameLegacyTargetDispatchTests: XCTestCase {
    func testLegacyPortRejectsWebSubsetBeforeDispatchButKeepsDefaultBuilds() async throws {
        let port = LegacySourceCI()
        let template = try XCTUnwrap(GameCIWorkflowTemplates.template(for: .unity))
        let source = GameBuildSourceTransport.repositorySnapshot(try .init(
            owner: "fixture", repository: "game", branch: "main",
            commitSHA: String(repeating: "b", count: 40), treeSHA: String(repeating: "c", count: 40),
            manifestDigest: String(repeating: "a", count: 64), revision: "fixture-revision"))
        let inputs = source.dispatchInputs(engine: .unity, engineVersion: "2022.3.62f1")
        let subset = try template.selection(forRequestedArtifacts: ["unity-web.zip"], inputs: inputs)
        do {
            _ = try await port.dispatch(template: template, source: source,
                engineVersion: "2022.3.62f1", targets: subset)
            XCTFail("a legacy port must not dispatch unrelated desktop/iOS jobs")
        } catch let error as GameBuildError {
            guard case .unsupportedTarget = error else { return XCTFail("wrong error: \(error)") }
        }
        let countBeforeDefault = await port.dispatched
        XCTAssertEqual(countBeforeDefault, 0)
        let defaults = try template.defaultSelection(inputs: inputs)
        let handle = try await port.dispatch(template: template, source: source,
            engineVersion: "2022.3.62f1", targets: defaults)
        let countAfterDefault = await port.dispatched
        XCTAssertEqual(handle.jobID, "legacy-source")
        XCTAssertEqual(countAfterDefault, 1)
    }
}
