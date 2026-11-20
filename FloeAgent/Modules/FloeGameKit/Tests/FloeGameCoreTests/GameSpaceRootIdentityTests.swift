// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeGameCore

final class GameSpaceRootIdentityTests: XCTestCase {
    /// Synthetic iOS container layout: .../Containers/Data/Application/<UUID>/
    /// Library/Application Support.
    private func supportURL(container: UUID) -> URL {
        URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/" + container.uuidString
            + "/Library/Application Support", isDirectory: true)
    }

    private func taskRoot(container: UUID, conversationID: UUID) -> String {
        "/private/var/mobile/Containers/Data/Application/" + container.uuidString
            + "/Library/Application Support/FloeAgent/PrivateTasks/" + conversationID.uuidString
    }

    func testConversationTaskRootPersistsRelocatableNamespacedIdentity() {
        let conversation = UUID(), workspace = UUID()
        let oldContainer = UUID(), newContainer = UUID()
        let owner = GameProjectOwner.conversation(conversationID: conversation, workspaceID: workspace)
        let oldPath = taskRoot(container: oldContainer, conversationID: conversation)
        let newPath = taskRoot(container: newContainer, conversationID: conversation)
        let expected = "chat-task:" + conversation.uuidString.lowercased()
            + "/" + workspace.uuidString.lowercased()

        XCTAssertEqual(GameSpaceRootIdentity.persistedPath(oldPath, owner: owner,
                                                           support: supportURL(container: oldContainer)),
                       expected)
        // A container UUID change (TestFlight update) maps to the same token.
        XCTAssertEqual(GameSpaceRootIdentity.persistedPath(newPath, owner: owner,
                                                           support: supportURL(container: newContainer)),
                       expected)
    }

    func testConversationTaskRootRejectsForeignConversationUUID() {
        let conversation = UUID(), workspace = UUID(), foreign = UUID()
        let container = UUID()
        let owner = GameProjectOwner.conversation(conversationID: conversation, workspaceID: workspace)
        let foreignPath = taskRoot(container: container, conversationID: foreign)
        XCTAssertEqual(GameSpaceRootIdentity.persistedPath(foreignPath, owner: owner,
                                                           support: supportURL(container: container)),
                       foreignPath)
    }

    func testConversationNonTaskRootsStayStrictAbsolute() {
        let conversation = UUID(), workspace = UUID()
        let container = UUID()
        let owner = GameProjectOwner.conversation(conversationID: conversation, workspaceID: workspace)
        let base = "/private/var/mobile/Containers/Data/Application/" + container.uuidString
            + "/Library/Application Support/FloeAgent/"
        // A sub-directory of the task root is not the exact task root.
        let nested = base + "PrivateTasks/" + conversation.uuidString + "/sub/dir"
        // An app-owned project root is not a chat task root.
        let projectRoot = base + "Projects/alpha"
        for path in [nested, projectRoot] {
            XCTAssertEqual(GameSpaceRootIdentity.persistedPath(path, owner: owner,
                                                               support: supportURL(container: container)),
                           path)
        }
    }

    func testSpaceLibraryIdentityUnchanged() {
        let record = UUID()
        let container = UUID()
        let owner = GameProjectOwner.space(recordID: record)
        let path = "/private/var/mobile/Containers/Data/Application/" + container.uuidString
            + "/Library/Application Support/FloeAgent/PersonalContent/" + record.uuidString
            + "/Game.floeproject/Game/Files"
        let expected = "space-library:" + record.uuidString + "/Game.floeproject/Game/Files"
        XCTAssertEqual(GameSpaceRootIdentity.persistedPath(path, owner: owner,
                                                           support: supportURL(container: container)),
                       expected)
    }
}
