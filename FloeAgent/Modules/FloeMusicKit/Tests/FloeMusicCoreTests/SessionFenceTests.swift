import XCTest
@testable import FloeMusicCore

/// Session fences: stale revisions, wrong owners, inactive vs closed,
/// persistence round-trip.
@MainActor
final class SessionFenceTests: XCTestCase {
    private func makeStore() async throws -> MusicProjectStore {
        try await MusicProjectStore(document: MusicFixtures.emptyDocument(),
                                    repository: FixtureMusicRepository())
    }

    func testStaleRevisionRejected() async throws {
        let store = try await makeStore()
        let first = await store.beginSession(ownerToken: "ai")
        try await store.commit(MusicEditBatch(baseRevision: 0, ops: [.setName("v1")]),
                               as: await store.beginSession(ownerToken: "editor"))
        // The AI session was opened at revision 0; the store has moved on.
        await XCTAssertThrowsErrorAsync(try await store.commit(
            MusicEditBatch(baseRevision: 0, ops: [.setName("ai-edit")]), as: first)) { error in
            guard case MusicError.staleRevision(let expected, let actual) = error else {
                return XCTFail("expected staleRevision, got \(error)")
            }
            XCTAssertEqual(expected, 0)
            XCTAssertEqual(actual, 1)
        }
        try await XCTAssertEqualAsync(try await store.currentSnapshot().name, "v1")
    }

    func testStaleOwnerRejected() async throws {
        let store = try await makeStore()
        let session = await store.beginSession(ownerToken: "render-1")
        // A different caller presenting the same session id must fail.
        let forged = MusicSessionHandle(sessionID: session.sessionID,
                                        ownerToken: "someone-else", baseRevision: 0)
        await XCTAssertThrowsErrorAsync(try await store.commit(
            MusicEditBatch(baseRevision: 0, ops: [.setName("x")]), as: forged)) { error in
            guard case MusicError.staleOwner = error else {
                return XCTFail("expected staleOwner, got \(error)")
            }
        }
    }

    func testInactiveFencesCommitsUntilReactivated() async throws {
        let store = try await makeStore()
        let session = await store.beginSession(ownerToken: "recorder")
        try await store.markInactive(session)
        await XCTAssertThrowsErrorAsync(try await store.commit(
            MusicEditBatch(baseRevision: 0, ops: [.setName("x")]), as: session)) { error in
            guard case MusicError.staleOwner = error else {
                return XCTFail("expected staleOwner for inactive session, got \(error)")
            }
        }
        try await store.reactivate(session)
        try await store.commit(MusicEditBatch(baseRevision: 0, ops: [.setName("rec")]),
                               as: session)
        try await XCTAssertEqualAsync(try await store.currentSnapshot().name, "rec")
    }

    func testClosedIsTerminalAndDistinctFromInactive() async throws {
        let store = try await makeStore()
        let session = await store.beginSession(ownerToken: "ai")
        try await store.markInactive(session)
        try await store.reactivate(session)
        try await store.close(session)
        await XCTAssertThrowsErrorAsync(try await store.commit(
            MusicEditBatch(baseRevision: 0, ops: [.setName("x")]), as: session)) { error in
            guard case MusicError.sessionClosed = error else {
                return XCTFail("expected sessionClosed, got \(error)")
            }
        }
        // Even reactivation cannot resurrect a closed session.
        await XCTAssertThrowsErrorAsync(try await store.reactivate(session))
        await XCTAssertThrowsErrorAsync(try await store.markInactive(session))
        await XCTAssertThrowsErrorAsync(try await store.commit(
            MusicEditBatch(baseRevision: 0, ops: [.setName("x")]), as: session)) { error in
            guard case MusicError.sessionClosed = error else {
                return XCTFail("expected sessionClosed after reactivate attempt, got \(error)")
            }
        }
    }

    func testUndoRequiresFreshBase() async throws {
        let store = try await makeStore()
        let stale = await store.beginSession(ownerToken: "editor")
        try await store.commit(MusicEditBatch(baseRevision: 0, ops: [.setName("v1")]),
                               as: await store.beginSession(ownerToken: "editor"))
        // Undo via a handle whose base revision is behind must fence.
        await XCTAssertThrowsErrorAsync(try await store.undo(stale)) { error in
            guard case MusicError.staleRevision = error else {
                return XCTFail("expected staleRevision, got \(error)")
            }
        }
        try await store.undo(await store.beginSession(ownerToken: "editor"))
        try await XCTAssertEqualAsync(try await store.currentSnapshot().name, "song")
    }

    func testPersistenceRoundTripThroughRepository() async throws {
        let repository = FixtureMusicRepository()
        let store = try await MusicProjectStore(document: MusicFixtures.emptyDocument(),
                                                repository: repository)
        let asset = try MusicFixtures.asset()
        try await store.commit(MusicEditBatch(baseRevision: 0, ops: [
            .insertAsset(asset), .setName("saved"),
        ]), as: await store.beginSession(ownerToken: "editor"))

        let reopened = try await repository.load(projectID: MusicProjectID(rawValue: "project-1"))
        XCTAssertEqual(reopened.name, "saved")
        XCTAssertEqual(reopened.revision, 1)
        XCTAssertEqual(reopened.assets.count, 1)
        try await XCTAssertEqualAsync(reopened, try await store.currentSnapshot())
    }
}
