// SPDX-License-Identifier: MPL-2.0
//
// workspace-core batch (job-d54a914f83a54585) — additive
// `conversation.get.workspace` projection tests. AUTHORED, NOT EXECUTED
// (Main runs the focused filter on the build resource). All reads/writes go
// through the REAL original stores on a file-backed schema-46 database via
// the existing RB3 test bed — no mirrored constants, no fixture-side
// shortcuts. The batch contract: nil/JSON-null is the honest UNBOUND, the
// projection NEVER scans a first workspace, and a bound row travels as the
// store's real identity/name/kind only.
import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
@testable import FloeAndroidCore

final class ConversationWorkspaceProjectionTests: XCTestCase {

    private func makeBundle(name: String = #function) async throws -> RB3TestBed.DomainBundle {
        let stores = try await RB3TestBed.stores(name: name)
        return RB3TestBed.makeDomain(stores: stores, lifecycle: nil)
    }

    /// Seeds ONE durable private-task workspace through the ORIGINAL store
    /// APIs (`saveWorkspace` + `assignConversation`) — the same statements
    /// the first-activation commit writes. No raw SQL fixture invention.
    private func bindPrivateTaskWorkspace(stores: RB3TestBed.Stores,
                                          conversation: ConversationRecord,
                                          name: String) async throws -> WorkspaceRecord {
        let record = WorkspaceRecord(
            name: name,
            rootBookmark: Data(),
            kind: .privateTask,
            internalRelativePath: "PrivateTasks/\(conversation.id.uuidString)"
        )
        try await stores.workspaces.saveWorkspace(record)
        try await stores.workspaces.assignConversation(workspaceID: record.id,
                                                       conversationID: conversation.id)
        return record
    }

    // MARK: - Honest unbound

    /// A header created by `conversation.create` (production path binds NO
    /// workspace) must project JSON null — never a first-workspace scan,
    /// never an empty-object reinterpretation.
    func testUnboundOrdinaryHeaderProjectsHonestNull() async throws {
        let bundle = try await makeBundle()
        let record = try await RB3TestBed.seedOrdinary(bundle.stores, title: "Fresh task")
        let reply = try await bundle.domain.get(conversationID: record.id)
        XCTAssertNil(reply.workspace, "unbound header must stay nil (no guess)")
        XCTAssertEqual(reply.wireObject["workspace"] as? NSNull, NSNull(),
                       "absence must travel as real JSON null, never a boxed Optional")
    }

    /// The memberwise init keeps every legacy call site byte-identical:
    /// omitting the trailing `workspace` argument yields nil.
    func testLegacyInitKeepsWorkspaceNil() async throws {
        let bundle = try await makeBundle()
        let record = try await RB3TestBed.seedOrdinary(bundle.stores, title: "Legacy shape")
        let reply = try await bundle.domain.get(conversationID: record.id)
        let legacy = ConversationSessionReply(
            conversationID: reply.conversationID, resourceID: reply.resourceID,
            revision: reply.revision, title: reply.title,
            createdAtRaw: reply.createdAtRaw, updatedAtRaw: reply.updatedAtRaw,
            titleOrigin: reply.titleOrigin, archivedAtRaw: reply.archivedAtRaw,
            firstScreen: reply.firstScreen, messagesTotalCount: reply.messagesTotalCount,
            runs: reply.runs, runsTotalCount: reply.runsTotalCount,
            runsTruncated: reply.runsTruncated,
            pendingInputs: reply.pendingInputs,
            pendingInputsTotalCount: reply.pendingInputsTotalCount,
            pendingInputsTruncated: reply.pendingInputsTruncated,
            taskPolicy: reply.taskPolicy)
        XCTAssertNil(legacy.workspace)
        XCTAssertEqual(legacy.wireObject["workspace"] as? NSNull, NSNull())
    }

    // MARK: - Real binding

    /// After the durable ownership rows exist, `get` projects the REAL
    /// workspace identity (store read, not text): exact id, persisted name,
    /// original kind vocabulary.
    func testBoundPrivateTaskProjectsRealIdentity() async throws {
        let bundle = try await makeBundle()
        let record = try await RB3TestBed.seedOrdinary(bundle.stores, title: "Readiness probe")
        let workspace = try await bindPrivateTaskWorkspace(stores: bundle.stores,
                                                           conversation: record,
                                                           name: "Readiness probe")
        let reply = try await bundle.domain.get(conversationID: record.id)
        let projected = try XCTUnwrap(reply.workspace)
        XCTAssertEqual(projected.workspaceID, workspace.id)
        XCTAssertEqual(projected.name, workspace.name)
        XCTAssertEqual(projected.kind, WorkspaceKind.privateTask.rawValue)
        let object = try XCTUnwrap(reply.wireObject["workspace"] as? [String: Any])
        XCTAssertEqual(object["workspaceID"] as? String, workspace.id.uuidString)
        XCTAssertEqual(object["name"] as? String, workspace.name)
        XCTAssertEqual(object["kind"] as? String, "privateTask")
        // The reply must also equal a directly-constructed wire from the
        // SAME record — the projection is the row, byte for byte.
        XCTAssertEqual(projected, ConversationWorkspaceWire(record: workspace))
    }

    /// The projection follows the CURRENT ownership row: a reassignment
    /// (delete + fresh activation shape) is reflected by the next page,
    /// never shadow-projected from the older one.
    func testProjectionFollowsReassignedOwnershipRow() async throws {
        let bundle = try await makeBundle()
        let record = try await RB3TestBed.seedOrdinary(bundle.stores, title: "Moved task")
        let old = try await bindPrivateTaskWorkspace(stores: bundle.stores,
                                                     conversation: record,
                                                     name: "Old workspace")
        let moved = WorkspaceRecord(
            name: "New workspace", rootBookmark: Data(), kind: .privateTask,
            internalRelativePath: "PrivateTasks/\(record.id.uuidString)")
        try await bundle.stores.workspaces.saveWorkspace(moved)
        try await bundle.stores.workspaces.assignConversation(workspaceID: moved.id,
                                                              conversationID: record.id)
        let reply = try await bundle.domain.get(conversationID: record.id)
        let projected = try XCTUnwrap(reply.workspace)
        XCTAssertEqual(projected.workspaceID, moved.id)
        XCTAssertNotEqual(projected.workspaceID, old.id)
        XCTAssertEqual(projected.name, "New workspace")
    }

    /// A renamed durable row lands in the NEXT page (the name is the row's,
    /// never a RAM reconstruction or a cached label).
    func testLongLegacyNameIsBoundedTo120CodePoints() async throws {
        let bundle = try await makeBundle()
        let record = try await RB3TestBed.seedOrdinary(bundle.stores, title: "Bound")
        let workspace = try await bindPrivateTaskWorkspace(
            stores: bundle.stores, conversation: record,
            name: String(repeating: "长名称", count: 60))
        let reply = try await bundle.domain.get(conversationID: record.id)
        let projected = try XCTUnwrap(reply.workspace)
        XCTAssertEqual(projected.name.count, 120)
        XCTAssertTrue(workspace.name.hasPrefix(projected.name))
    }
}
