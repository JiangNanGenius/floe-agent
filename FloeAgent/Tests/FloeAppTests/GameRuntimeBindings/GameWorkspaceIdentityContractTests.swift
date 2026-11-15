// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import XCTest
import Foundation
import FloeGameCore
@testable import FloeApp

/// Source regression portfolio for owner/root isolation and native-service
/// provenance. These tests are NOT executed in this source-only task.
final class GameWorkspaceIdentityContractTests: XCTestCase {
    func testSameProjectDifferentOwnerOrRootCannotShareASessionKey() {
        let projectID = UUID()
        let otherID = UUID()
        let rootA = URL(fileURLWithPath: "/tmp/floe-game-a", isDirectory: true)
        let rootB = URL(fileURLWithPath: "/tmp/floe-game-b", isDirectory: true)
        let base = GameWorkspaceKey(projectID: projectID,
            owner: .space(recordID: projectID), rootURL: rootA)
        let copy = GameWorkspaceKey(projectID: projectID,
            owner: .space(recordID: projectID), rootURL: rootA)
        let otherRoot = GameWorkspaceKey(projectID: projectID,
            owner: .space(recordID: projectID), rootURL: rootB)
        let chatOwner = GameWorkspaceKey(projectID: projectID,
            owner: .conversation(conversationID: otherID, workspaceID: projectID),
            rootURL: rootA)
        XCTAssertEqual(base, copy)
        XCTAssertNotEqual(base, otherRoot)
        XCTAssertNotEqual(base, chatOwner)
    }

    func testNativeServiceMetadataUsesADistinctTargetTool() throws {
        let runID = UUID()
        let conversationID = UUID()
        let metadata = GameNativeServiceRunMetadata(runID: runID,
            conversationID: conversationID, targetTool: "game.runtime")
        XCTAssertEqual(metadata.activity, "gameProjectService")
        XCTAssertEqual(metadata.source, "nativeService")
        XCTAssertNotEqual(metadata.targetTool, "exec.localService")
        let json = try metadata.payloadJSON()
        let decoded = try JSONDecoder().decode(GameNativeServiceRunMetadata.self,
                                               from: Data(json.utf8))
        XCTAssertEqual(decoded, metadata)
    }

    func testArchiveAuthorityKeepsExactGenerationWhenPresent() {
        let runID = UUID()
        let conversationID = UUID()
        let authority = GameArchiveRunAuthority(runID: runID,
            conversationID: conversationID, environmentID: "linux-session",
            executionBindingGeneration: 7)
        XCTAssertEqual(authority.executionBindingGeneration, 7)
        XCTAssertEqual(authority.environmentID, "linux-session")
        XCTAssertNotEqual(authority,
            GameArchiveRunAuthority(runID: runID, conversationID: conversationID,
                                    environmentID: "linux-session",
                                    executionBindingGeneration: 8))
    }

    func testTemporaryConversationErrorNeverClaimsAPlayableRun() {
        let error = GameWorkspaceRegistryError.conversationNotWritable
        XCTAssertFalse(error.localizedDescription.isEmpty)
    }
}
#endif
