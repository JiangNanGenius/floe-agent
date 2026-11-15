// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import FloeGameCore
import FloeGameBuildKit
@testable import FloeGameExecutionBridge

private struct GameSourceCompanionPropagationProvider: GameDistributionPairedSourceProvider {
    let resolution: GameDistributionPairedSourceResolution

    func resolve(_ artifactID: String) async throws -> GameDistributionPairedSourceResolution? {
        artifactID == "love-runtime-and-source-2" ? resolution : nil
    }
}

/// Source-only regression for the additive captured-provider seam. The stable
/// `GameExecutionBuildRequest` stays Equatable; the provider travels as a
/// separate argument and is only composed into a distribution request when an
/// explicit profile is present. These tests are authored but NOT executed in
/// this source-only task.
final class GameSourceCompanionPropagationTests: XCTestCase {
    func testCompositionCarriesCapturedProviderOnlyWithAnExplicitProfile() async throws {
        let url = URL(fileURLWithPath: "/tmp/exact/love-runtime-and-source.zip")
        let provider = GameSourceCompanionPropagationProvider(
            resolution: .init(url: url, sha256: String(repeating: "a", count: 64), bytes: 1_024))
        XCTAssertNil(GameExecutionDistributionComposition.request(
            profileID: nil, pairedProvider: provider))

        let request = try XCTUnwrap(GameExecutionDistributionComposition.request(
            profileID: "portable-love", pairedProvider: provider))
        XCTAssertEqual(request.profileID, "portable-love")
        XCTAssertEqual(request.mode, .distribution)
        let resolved = try await request.pairedProvider?
            .resolve("love-runtime-and-source-2")
        XCTAssertEqual(resolved?.url, url)
        XCTAssertEqual(resolved?.bytes, 1_024)
        let unknown = try await request.pairedProvider?.resolve("another-source")
        XCTAssertNil(unknown)
    }

    func testCompositionWithoutProviderKeepsTheExistingClosedPath() throws {
        let request = try XCTUnwrap(GameExecutionDistributionComposition.request(
            profileID: "portable-love", pairedProvider: nil))
        XCTAssertNil(request.pairedProvider)
        XCTAssertEqual(request.mode, .distribution)
        XCTAssertNil(GameExecutionDistributionComposition.request(
            profileID: nil, pairedProvider: nil))
    }
}
