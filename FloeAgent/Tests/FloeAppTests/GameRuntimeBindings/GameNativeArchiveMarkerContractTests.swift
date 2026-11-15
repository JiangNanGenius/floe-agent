// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import XCTest
import Foundation
import FloePersistence
import FloeModels
@testable import FloeApp

/// Source-only regression for the pre-environment bind exemption. A genuine
/// host-written persisted archive marker may allow the FIRST binding; goal text
/// alone, forged/owner-mismatched metadata and unrelated runs must still block.
/// These tests are NOT executed in this HOLD.
final class GameNativeArchiveMarkerContractTests: XCTestCase {
    private let conversationID = UUID()
    private let projectID = UUID()
    private let runID = UUID()

    private func root() -> URL {
        URL(fileURLWithPath: "/tmp/floe-game-archive-marker", isDirectory: true)
    }

    private func archiveRun(end: Date? = Date()) -> RunRecord {
        RunRecord(id: runID, conversationID: conversationID, state: "completed",
                  goal: "Game project archive service",
                  startedAt: Date(), endedAt: end, executionBinding: nil)
    }

    private func event(_ metadata: GameNativeServiceRunMetadata,
                       kind: RunEventRecord.Kind = .status) throws -> RunEventRecord {
        RunEventRecord(runID: runID, sequence: 1, kind: kind,
                       payloadJSON: try metadata.payloadJSON())
    }

    func testGenuinePersistedArchiveMarkerIsTrusted() throws {
        let metadata = GameNativeServiceRunMetadata(
            runID: runID, conversationID: conversationID, targetTool: "game.archive",
            projectID: projectID, workspaceRootPath: root().standardizedFileURL.path)
        XCTAssertTrue(GameWorkspaceRegistry.isTrustedNativeArchiveMarker(
            archiveRun(), events: [try event(metadata)],
            conversationID: conversationID, projectID: projectID, rootPath: root()))
    }

    func testSameGoalUserRunWithoutMarkerStillBlocks() {
        XCTAssertFalse(GameWorkspaceRegistry.isTrustedNativeArchiveMarker(
            archiveRun(), events: [],
            conversationID: conversationID, projectID: projectID, rootPath: root()))
    }

    func testForgedOwnerProjectRootAndTargetAreRejected() throws {
        let otherRun = UUID()
        let otherConversation = UUID()
        let otherProject = UUID()
        let otherRoot = URL(fileURLWithPath: "/tmp/floe-other-root", isDirectory: true)
        let valid = GameNativeServiceRunMetadata(
            runID: runID, conversationID: conversationID, targetTool: "game.archive",
            projectID: projectID, workspaceRootPath: root().standardizedFileURL.path)

        let wrongRun = GameNativeServiceRunMetadata(
            runID: otherRun, conversationID: conversationID, targetTool: "game.archive",
            projectID: projectID, workspaceRootPath: root().standardizedFileURL.path)
        let wrongConversation = GameNativeServiceRunMetadata(
            runID: runID, conversationID: otherConversation, targetTool: "game.archive",
            projectID: projectID, workspaceRootPath: root().standardizedFileURL.path)
        let wrongProject = GameNativeServiceRunMetadata(
            runID: runID, conversationID: conversationID, targetTool: "game.archive",
            projectID: otherProject, workspaceRootPath: root().standardizedFileURL.path)
        let wrongRoot = GameNativeServiceRunMetadata(
            runID: runID, conversationID: conversationID, targetTool: "game.archive",
            projectID: projectID, workspaceRootPath: otherRoot.standardizedFileURL.path)
        let wrongTarget = GameNativeServiceRunMetadata(
            runID: runID, conversationID: conversationID, targetTool: "game.runtime",
            projectID: projectID, workspaceRootPath: root().standardizedFileURL.path)

        for metadata in [wrongRun, wrongConversation, wrongProject, wrongRoot, wrongTarget] {
            XCTAssertFalse(GameWorkspaceRegistry.isTrustedNativeArchiveMarker(
                archiveRun(), events: [try event(metadata)],
                conversationID: conversationID, projectID: projectID, rootPath: root()))
        }
        XCTAssertTrue(GameWorkspaceRegistry.isTrustedNativeArchiveMarker(
            archiveRun(), events: [try event(valid)],
            conversationID: conversationID, projectID: projectID, rootPath: root()))
    }

    func testWrongEventKindAndUnrelatedOwnerRunAreRejected() throws {
        let metadata = GameNativeServiceRunMetadata(
            runID: runID, conversationID: conversationID, targetTool: "game.archive",
            projectID: projectID, workspaceRootPath: root().standardizedFileURL.path)
        XCTAssertFalse(GameWorkspaceRegistry.isTrustedNativeArchiveMarker(
            archiveRun(), events: [try event(metadata, kind: .notice)],
            conversationID: conversationID, projectID: projectID, rootPath: root()))
        let unrelated = RunRecord(id: UUID(), conversationID: UUID(), state: "completed",
                                  goal: "Game project archive service",
                                  startedAt: Date(), endedAt: Date(), executionBinding: nil)
        XCTAssertFalse(GameWorkspaceRegistry.isTrustedNativeArchiveMarker(
            unrelated, events: [try event(metadata)],
            conversationID: conversationID, projectID: projectID, rootPath: root()))
    }
}
#endif
