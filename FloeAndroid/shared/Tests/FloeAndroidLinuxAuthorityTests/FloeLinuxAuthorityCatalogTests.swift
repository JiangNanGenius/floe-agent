// SPDX-License-Identifier: MPL-2.0
//
// Full120 catalog-paging repair — focused host regressions for the ADDITIVE
// bounded `listPage` enumeration (and the frozen legacy V1 `list`).
//
// These tests run the ORIGINAL FloeEnvironments registry on the macOS host
// against task-owned scratch roots (no device, no backend process, no model
// call). The large fixture is a REAL registry: records are created through
// `EnvironmentRegistry.ensureProjectContainer` / `ensureSessionContainer`
// (the same original creation path the runtime uses) and persisted to the
// original `containers.json`, then loaded by a fresh `FloeLinuxAuthority`.
// Its legacy global metadata reply is measured to exceed the frozen 65536-byte
// wire ceiling — the exact condition behind the device's
// `authority_replyTooLarge` receipt — while scoped/global pages reconstruct it
// completely within the same ceiling.

import XCTest
import Foundation
import FloeCore
import FloeEnvironments
@testable import FloeAndroidLinuxAuthority

final class FloeLinuxAuthorityCatalogTests: XCTestCase {
    private var scratch: URL!
    private var authority: FloeLinuxAuthority!
    private var info: LinuxAuthorityConfigureInfo!
    private let baseRevision = "catalog-paging-fixture"

    private var stateRoot: String { scratch.appendingPathComponent("state").path }
    private var workspacesRoot: String { scratch.appendingPathComponent("workspaces").path }
    private var baseRoot: String { scratch.appendingPathComponent("base").path }

    override func setUp() async throws {
        try await super.setUp()
        let base = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent("FloeAndroidAuthorityCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        scratch = base
        authority = FloeLinuxAuthority()
        info = try await authority.configure(.init(stateRoot: stateRoot, workspacesRoot: workspacesRoot,
                                                   baseRoot: baseRoot, baseRevision: baseRevision))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
        try await super.tearDown()
    }

    // MARK: - Fixture helpers (ORIGINAL registry creation path)

    private func makeRegistry() async throws -> EnvironmentRegistry {
        let roots = try EnvironmentRoots.makeTrusted(rootURL: URL(fileURLWithPath: info.stateRoot, isDirectory: true))
        let registry = EnvironmentRegistry(roots: roots, baseRevision: baseRevision,
                                           compatibleBaseRevisions: [], defaultExecutionBackend: .linuxPRoot)
        try await registry.prepare()
        return registry
    }

    /// A FRESH authority actor on the same configured roots: its registry
    /// re-reads the persisted `containers.json`, which is how a runtime
    /// restart sees records created by another (or an earlier) process.
    private func reloadedAuthority() async throws -> FloeLinuxAuthority {
        let fresh = FloeLinuxAuthority()
        _ = try await fresh.configure(.init(stateRoot: info.stateRoot, workspacesRoot: info.workspacesRoot,
                                            baseRoot: info.baseRoot, baseRevision: baseRevision))
        return fresh
    }

    private func workspacePath(_ projectID: UUID) -> String {
        info.workspacesRoot + "/" + projectID.uuidString
    }

    private func ownerDigest(_ projectID: UUID) -> String {
        FloeDigest.sha256Hex(Data(workspacePath(projectID).utf8))
    }

    @discardableResult
    private func createProject(_ registry: EnvironmentRegistry, projectID: UUID, sessions: Int) async throws -> String {
        let owner = ownerDigest(projectID)
        _ = try await registry.ensureProjectContainer(workspaceID: owner,
                                                      workspaceRootPath: workspacePath(projectID))
        for _ in 0..<sessions {
            _ = try await registry.ensureSessionContainer(conversationID: UUID().uuidString,
                                                          workspaceID: owner,
                                                          workspaceRootPath: workspacePath(projectID),
                                                          inheritFromProject: true)
        }
        return owner
    }

    private struct LargeFixture {
        var authority: FloeLinuxAuthority
        var projectID: UUID
        var owner: String
        var recordCount: Int
    }

    /// 12 project records, 243 session records and the shared layer for a
    /// deterministic real registry whose legacy reply is > 64 KiB.
    private func makeLargeFixture() async throws -> LargeFixture {
        let registry = try await makeRegistry()
        let scopedProject = UUID()
        let owner = try await createProject(registry, projectID: scopedProject, sessions: 3)
        for index in 0..<11 {
            try await createProject(registry, projectID: UUID(), sessions: index == 0 ? 20 : 22)
        }
        let fresh = try await reloadedAuthority()
        let count = try await fresh.list().environments.count
        return LargeFixture(authority: fresh, projectID: scopedProject, owner: owner, recordCount: count)
    }

    // MARK: - Reply helpers

    private func decoded(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func failureCode(_ data: Data) -> String? {
        guard let outcome = decoded(data)["outcome"] as? [String: Any],
              let failure = outcome["failure"] as? [String: Any] else { return nil }
        return failure["code"] as? String
    }

    private func successPage(_ data: Data) -> [String: Any]? {
        guard let outcome = decoded(data)["outcome"] as? [String: Any],
              let ok = outcome["ok"] as? [String: Any] else { return nil }
        return ok["listPage"] as? [String: Any]
    }

    private func pageRequest(projectID: String? = nil, cursor: String? = nil,
                             limit: Int? = nil, requestID: String = "catalog-page") -> Data {
        var payload: [String: Any] = [:]
        if let projectID { payload["projectID"] = projectID }
        if let cursor { payload["cursor"] = cursor }
        if let limit { payload["limit"] = limit }
        let envelope: [String: Any] = ["version": 1, "requestID": requestID,
                                       "operation": ["listPage": payload]]
        return try! JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    private func errorCode(_ block: () async throws -> LinuxAuthorityEnvironmentPage) async -> LinuxAuthorityErrorCode? {
        do {
            _ = try await block()
            return nil
        } catch let error as LinuxAuthorityError {
            return error.code
        } catch {
            XCTFail("unexpected error type: \(error)")
            return .internalError
        }
    }

    private func metadataRow(id: String, kind: ContainerKind, ownerID: String?,
                             name: String? = nil, parentID: String? = nil,
                             rebuildReason: String? = nil,
                             baseRevision: String = "catalog-paging-fixture") -> LinuxAuthorityEnvironmentMetadata {
        LinuxAuthorityEnvironmentMetadata(
            id: id, kind: kind.rawValue, ownerID: ownerID, name: name, state: "active",
            baseRevision: baseRevision, requiresRebuild: rebuildReason != nil,
            rebuildReason: rebuildReason, executionBackend: "linuxPRoot", bytes: 0,
            packageCount: 0, parentID: parentID, templateID: nil, layerFormat: 1)
    }

    // MARK: - The measured defect + complete global paging

    func testOverflowingLegacyReplyIsRejectedWhileGlobalPagesCoverEveryRowExactlyOnce() async throws {
        let fixture = try await makeLargeFixture()
        XCTAssertGreaterThan(fixture.recordCount, 250, "fixture must be a genuinely large registry")

        // 1. The ORIGINAL legacy reply still fails closed (the measured
        //    `authority_replyTooLarge` receipt), never a truncated success.
        let legacy = await fixture.authority.exchange(
            Data(#"{"version":1,"requestID":"legacy-global","operation":"list"}"#.utf8))
        XCTAssertLessThanOrEqual(legacy.count, LinuxAuthorityWire.maximumBytes)
        XCTAssertEqual(failureCode(legacy), "replyTooLarge",
                       "the fixture must reproduce the device's overflowing legacy reply")

        // 2. The overflowing source is real: the complete typed metadata list
        //    encodes past the ceiling.
        let all = try await fixture.authority.list()
        XCTAssertEqual(all.environments.count, fixture.recordCount)
        let encodedAll = try JSONEncoder().encode(all.environments)
        XCTAssertGreaterThan(encodedAll.count, LinuxAuthorityWire.maximumBytes)

        // 3. GLobal pages reconstruct the whole inventory through the REAL
        //    wire entry, each reply bounded, no duplicate and no loss.
        var observed: [String] = []
        var seen = Set<String>()
        var cursor: String?
        var pages = 0
        var previousOffset = -1
        repeat {
            let reply = await fixture.authority.exchange(
                pageRequest(cursor: cursor, limit: 50, requestID: "global-page-\(pages)"))
            XCTAssertLessThanOrEqual(reply.count, LinuxAuthorityWire.maximumBytes)
            let page = try XCTUnwrap(successPage(reply), "expected ok.listPage: \(String(decoding: reply, as: UTF8.self))")
            XCTAssertEqual(page["scope"] as? String, "all")
            XCTAssertEqual(page["total"] as? Int, fixture.recordCount)
            XCTAssertTrue(page["projectID"] is NSNull)
            XCTAssertTrue(page["workspaceOwnerID"] is NSNull)
            let rows = try XCTUnwrap(page["environments"] as? [[String: Any]])
            XCTAssertFalse(rows.isEmpty, "a non-terminal page never returns an empty success")
            XCTAssertLessThanOrEqual(rows.count, 50)
            for row in rows {
                let id = try XCTUnwrap(row["id"] as? String)
                XCTAssertTrue(seen.insert(id).inserted, "duplicate row across pages: \(id)")
                observed.append(id)
            }
            if let raw = page["nextCursor"], !(raw is NSNull) {
                let next = try XCTUnwrap(raw as? String, "nextCursor must be a string or null")
                let decoded = try XCTUnwrap(LinuxAuthorityCatalogCursor.decode(next))
                XCTAssertGreaterThan(decoded.offset, previousOffset)
                previousOffset = decoded.offset
                cursor = next
            } else {
                cursor = nil
            }
            pages += 1
            XCTAssertLessThanOrEqual(pages, 64, "paging must terminate")
        } while cursor != nil

        XCTAssertGreaterThan(pages, 1, "the fixture must need more than one page")
        XCTAssertEqual(observed, all.environments.map(\.id),
                       "complete pages must reproduce the id-sorted inventory exactly")

        // 4. The MEASURED device path: the SAME oversized registry answers the
        //    requested project in ONE bounded scoped reply (project + its 3
        //    sessions), while the global legacy reply above cannot be produced
        //    at all. This is the first-Send catalog shape.
        let scoped = await fixture.authority.exchange(
            pageRequest(projectID: fixture.projectID.uuidString, limit: 200, requestID: "scoped-on-large"))
        XCTAssertLessThanOrEqual(scoped.count, LinuxAuthorityWire.maximumBytes)
        let scopedPage = try XCTUnwrap(successPage(scoped),
                                       "expected ok.listPage: \(String(decoding: scoped, as: UTF8.self))")
        XCTAssertEqual(scopedPage["scope"] as? String, "project")
        XCTAssertEqual(scopedPage["projectID"] as? String, fixture.projectID.uuidString)
        XCTAssertEqual(scopedPage["workspaceOwnerID"] as? String, fixture.owner)
        XCTAssertEqual(scopedPage["total"] as? Int, 4)
        XCTAssertEqual((scopedPage["environments"] as? [[String: Any]])?.count, 4)
        XCTAssertTrue(scopedPage["nextCursor"] is NSNull)
    }

    // MARK: - Exact project/session scoping

    func testScopedPagesReconstructOnlyTheRequestedProjectInventory() async throws {
        let registry = try await makeRegistry()
        let project = UUID()
        let owner = try await createProject(registry, projectID: project, sessions: 3)
        let foreign = UUID()
        try await createProject(registry, projectID: foreign, sessions: 2)
        let reader = try await reloadedAuthority()

        let all = try await reader.list().environments
        let projectIDs = Set(all.filter { $0.kind == "project" && $0.ownerID == owner }.map(\.id))
        let expected = all.filter { row in
            if row.kind == "project" { return row.ownerID == owner }
            return row.kind == "session" && row.parentID.map(projectIDs.contains) == true
        }
        XCTAssertEqual(expected.count, 4, "1 project record + 3 session records")
        XCTAssertEqual(projectIDs.count, 1)

        var collected: [String] = []
        var cursor: String?
        var pages = 0
        repeat {
            let reply = await reader.exchange(pageRequest(projectID: project.uuidString.lowercased(),
                                                          cursor: cursor, limit: 2,
                                                          requestID: "scoped-page-\(pages)"))
            XCTAssertLessThanOrEqual(reply.count, LinuxAuthorityWire.maximumBytes)
            let page = try XCTUnwrap(successPage(reply), "expected ok.listPage: \(String(decoding: reply, as: UTF8.self))")
            XCTAssertEqual(page["scope"] as? String, "project")
            XCTAssertEqual(page["projectID"] as? String, project.uuidString)
            XCTAssertEqual(page["workspaceOwnerID"] as? String, owner)
            XCTAssertEqual(page["total"] as? Int, 4)
            let rows = try XCTUnwrap(page["environments"] as? [[String: Any]])
            XCTAssertFalse(rows.isEmpty)
            XCTAssertLessThanOrEqual(rows.count, 2)
            for row in rows {
                let kind = try XCTUnwrap(row["kind"] as? String)
                if kind == "project" {
                    XCTAssertEqual(row["ownerID"] as? String, owner, "foreign project row leaked into a scoped page")
                } else {
                    XCTAssertEqual(kind, "session")
                    let parent = try XCTUnwrap(row["parentID"] as? String)
                    XCTAssertTrue(projectIDs.contains(parent), "foreign session row leaked into a scoped page")
                }
                collected.append(try XCTUnwrap(row["id"] as? String))
            }
            cursor = (page["nextCursor"] as? String)
            pages += 1
        } while cursor != nil

        XCTAssertEqual(pages, 2)
        XCTAssertEqual(collected, expected.map(\.id))

        // The reply is metadata only: no configured/workspace/scratch paths.
        let text = String(decoding: await reader.exchange(pageRequest(projectID: project.uuidString, limit: 2)),
                          as: UTF8.self)
        XCTAssertFalse(text.contains(info.stateRoot))
        XCTAssertFalse(text.contains(info.workspacesRoot))
        XCTAssertFalse(text.contains(scratch.path))
    }

    func testScopedPageForAnUnknownProjectIsACoherentEmptyPage() async throws {
        let project = UUID()
        let page = try await authority.listPage(.init(projectID: project.uuidString))
        XCTAssertEqual(page.scope, "project")
        XCTAssertEqual(page.projectID, project.uuidString)
        XCTAssertEqual(page.workspaceOwnerID?.count, 64)
        XCTAssertEqual(page.total, 0)
        XCTAssertTrue(page.environments.isEmpty)
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(page.baseRevision, baseRevision)
    }

    // MARK: - Cursor + limit validation

    func testStrictCursorAndLimitValidationNeverReturnsRows() async throws {
        let registry = try await makeRegistry()
        let project = UUID()
        try await createProject(registry, projectID: project, sessions: 2)
        let reader = try await reloadedAuthority()
        let first = try await reader.listPage(.init(projectID: project.uuidString, limit: 1))
        let cursor = try XCTUnwrap(first.nextCursor)
        let pieces = cursor.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(pieces.count, 3)
        let fingerprint = String(pieces[1])
        let total = first.total

        let malformed = [
            "",
            "v2.\(fingerprint).0",
            "v1.\(String(fingerprint.dropLast())).0",
            "v1.\(fingerprint)0.0",
            "v1.\(fingerprint.uppercased()).0",
            "v1.\(fingerprint).00",
            "v1.\(fingerprint).+1",
            "v1.\(fingerprint).-1",
            "v1.\(fingerprint).1.2",
            "v1.\(fingerprint).12345678901",
            "v1.\(fingerprint).abc",
            "v1..0",
            String(repeating: "v", count: 97),
        ]
        for raw in malformed {
            let code = await errorCode {
                try await reader.listPage(.init(projectID: project.uuidString, cursor: raw, limit: 1))
            }
            XCTAssertEqual(code, .invalidWire, "cursor \(raw.debugDescription) must fail closed")
        }

        // Valid shape, DIFFERENT snapshot digest → retryable catalogChanged.
        let foreignFingerprint = String(repeating: fingerprint == String(repeating: "a", count: 64) ? "b" : "a",
                                        count: 64)
        let changed = await errorCode {
            try await reader.listPage(.init(projectID: project.uuidString,
                                            cursor: "v1.\(foreignFingerprint).0", limit: 1))
        }
        XCTAssertEqual(changed, .catalogChanged)

        // Correct digest but an offset beyond the filtered inventory.
        let beyond = await errorCode {
            try await reader.listPage(.init(projectID: project.uuidString,
                                            cursor: "v1.\(fingerprint).\(total + 1)", limit: 1))
        }
        XCTAssertEqual(beyond, .invalidWire)

        // Limits: absent is the bounded default; 1...200 valid; everything
        // else a wire-shape refusal (never silently clamped).
        let defaulted = try await reader.listPage(.init(projectID: project.uuidString))
        XCTAssertEqual(defaulted.total, 3, "1 project + 2 sessions")
        XCTAssertEqual(defaulted.environments.count, 3)
        XCTAssertNil(defaulted.nextCursor)
        for limit in [0, -1, 201, 10_000] {
            let code = await errorCode {
                try await reader.listPage(.init(projectID: project.uuidString, limit: limit))
            }
            XCTAssertEqual(code, .invalidWire, "limit \(limit)")
        }

        let wrongTypes: [String] = [
            #"{"version":1,"operation":{"listPage":{"limit":"5"}}}"#,
            #"{"version":1,"operation":{"listPage":{"limit":2.5}}}"#,
            #"{"version":1,"operation":{"listPage":{"projectID":5}}}"#,
            #"{"version":1,"operation":{"listPage":{"cursor":7}}}"#,
            #"{"version":1,"operation":{"listPage":{"limit":1,"offset":1}}}"#,
            #"{"version":1,"operation":"listPage"}"#,
            #"{"version":1,"operation":{"listPage":{},"list":{}}}"#,
        ]
        for raw in wrongTypes {
            let reply = await reader.exchange(Data(raw.utf8))
            XCTAssertEqual(failureCode(reply), "invalidWire", "case \(raw)")
        }
        // A project selection reuses the ORIGINAL canonical-UUID gate, so a
        // malformed id is `invalidUUID` (not a silent empty success).
        for raw in [
            #"{"version":1,"operation":{"listPage":{"projectID":"not-a-uuid"}}}"#,
            #"{"version":1,"operation":{"listPage":{"projectID":".."}}}"#,
        ] {
            let reply = await reader.exchange(Data(raw.utf8))
            XCTAssertEqual(failureCode(reply), "invalidUUID", "case \(raw)")
        }

        // Documented null-equivalence: cursor/projectID JSON null == absent.
        let nullFirst = await reader.exchange(
            Data(#"{"version":1,"operation":{"listPage":{"projectID":null,"cursor":null,"limit":1}}}"#.utf8))
        let nullPage = try XCTUnwrap(successPage(nullFirst))
        XCTAssertEqual(nullPage["scope"] as? String, "all")
    }

    // MARK: - Inventory change between pages

    func testCursorFromAChangedInventoryIsARetryableTypedRefusal() async throws {
        let registry = try await makeRegistry()
        let project = UUID()
        let owner = try await createProject(registry, projectID: project, sessions: 2)
        let reader = try await reloadedAuthority()
        let first = try await reader.listPage(.init(projectID: project.uuidString, limit: 2))
        XCTAssertEqual(first.total, 3)
        let cursor = try XCTUnwrap(first.nextCursor)

        // The ORIGINAL creation path mutates the SAME registry while a page
        // cursor is outstanding (another process/restart, not a fake input).
        let mutator = try await makeRegistry()
        _ = try await mutator.ensureSessionContainer(conversationID: UUID().uuidString,
                                                     workspaceID: owner,
                                                     workspaceRootPath: workspacePath(project),
                                                     inheritFromProject: true)
        let reloaded = try await reloadedAuthority()

        let stale = await errorCode {
            try await reloaded.listPage(.init(projectID: project.uuidString, cursor: cursor, limit: 2))
        }
        XCTAssertEqual(stale, .catalogChanged, "a mixed inventory must never be paged")

        let restarted = try await reloaded.listPage(.init(projectID: project.uuidString, limit: 2))
        XCTAssertEqual(restarted.total, 4, "the retry-without-cursor path sees the new record")
        XCTAssertNotNil(restarted.nextCursor)

        // A cursor is also invalidated by a metadata CHANGE, not just an
        // insertion (the fingerprint covers every returned field).
        let partial = try await reloaded.listPage(.init(projectID: project.uuidString, limit: 3))
        let outstanding = try XCTUnwrap(partial.nextCursor)
        let sessionID = try XCTUnwrap(partial.environments.last?.id)
        let changer = try await makeRegistry()
        try await changer.markRebuild(id: sessionID, reason: "catalog paging change probe")
        let changed = try await reloadedAuthority()
        let changedCode = await errorCode {
            try await changed.listPage(.init(projectID: project.uuidString, cursor: outstanding, limit: 3))
        }
        XCTAssertEqual(changedCode, .catalogChanged)
    }

    // MARK: - Oversized single rows: explicit failure, never a silent drop

    func testASingleRowThatCannotFitIsAnExplicitFailureNotATruncatedOrEmptyPage() async throws {
        let registry = try await makeRegistry()
        let project = UUID()
        let owner = ownerDigest(project)
        _ = try await registry.ensureProjectContainer(workspaceID: owner,
                                                      workspaceRootPath: workspacePath(project))
        let session = try await registry.ensureSessionContainer(conversationID: UUID().uuidString,
                                                                workspaceID: owner,
                                                                workspaceRootPath: workspacePath(project),
                                                                inheritFromProject: true)
        try await registry.markRebuild(id: session.id, reason: String(repeating: "r", count: 70_000))
        let reader = try await reloadedAuthority()

        var collected = 0
        var cursor: String?
        var sawRefusal = false
        var claimedComplete = false
        for _ in 0..<4 {
            do {
                let page = try await reader.listPage(.init(projectID: project.uuidString,
                                                           cursor: cursor, limit: 2))
                XCTAssertEqual(page.total, 2)
                XCTAssertFalse(page.environments.isEmpty,
                               "a successful page always contains at least one complete row")
                collected += page.environments.count
                cursor = page.nextCursor
                if cursor == nil {
                    claimedComplete = true
                    break
                }
            } catch let error as LinuxAuthorityError {
                XCTAssertEqual(error.code, .replyTooLarge)
                sawRefusal = true
                break
            }
        }
        XCTAssertTrue(sawRefusal, "the oversized row must surface an explicit refusal")
        XCTAssertFalse(claimedComplete, "the catalog must never succeed while a row was dropped")
        XCTAssertLessThan(collected, 2)

        // A scope containing ONLY the oversized row refuses on its first page
        // (no empty success with a fabricated terminal cursor).
        let onlyOversized = UUID()
        let onlyOwner = ownerDigest(onlyOversized)
        let mutator = try await makeRegistry()
        let onlyProject = try await mutator.ensureProjectContainer(
            workspaceID: onlyOwner, workspaceRootPath: workspacePath(onlyOversized))
        try await mutator.markRebuild(id: onlyProject.id,
                                      reason: String(repeating: "x", count: 70_000))
        let onlyReader = try await reloadedAuthority()
        let code = await errorCode {
            try await onlyReader.listPage(.init(projectID: onlyOversized.uuidString, limit: 1))
        }
        XCTAssertEqual(code, .replyTooLarge)
    }

    // MARK: - Page builder byte budget (synthetic, deterministic)

    func testPageBuilderFillsOnlyCompleteRowsAndAdvancesTheCursor() throws {
        let rows = (0..<50).map { index in
            metadataRow(id: String(format: "00000000-0000-4000-8000-%012d", index),
                        kind: .session, ownerID: "owner", parentID: "project")
        }
        let fingerprint = LinuxAuthorityCatalogCursor.fingerprint(scope: .all,
                                                                 baseRevision: baseRevision, rows: rows)
        let page = try LinuxAuthorityCatalogPageBuilder.page(scope: .all, baseRevision: baseRevision,
                                                             fingerprint: fingerprint, rows: rows,
                                                             offset: 0, limit: 200)
        XCTAssertEqual(page.environments.count, 50)
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(page.total, 50)

        // A call with a limit above the bounded maximum is a programmer error
        // guard only; the authority validates it before this builder.
        let firstPage = try LinuxAuthorityCatalogPageBuilder.page(scope: .all, baseRevision: baseRevision,
                                                                  fingerprint: fingerprint, rows: rows,
                                                                  offset: 0, limit: 20)
        XCTAssertEqual(firstPage.environments, Array(rows[0..<20]))
        let decoded = try XCTUnwrap(LinuxAuthorityCatalogCursor.decode(try XCTUnwrap(firstPage.nextCursor)))
        XCTAssertEqual(decoded.offset, 20)
        XCTAssertEqual(decoded.fingerprint, fingerprint)
    }

    func testPageBuilderShrinksByCompleteRowsUnderTheWireCeiling() throws {
        // Ten 10 KiB names: at most a handful fit; every returned row is
        // returned EXACTLY (no partial/truncated field) and the cursor lands
        // on the first omitted row.
        let rows = (0..<10).map { index in
            metadataRow(id: String(format: "10000000-0000-4000-8000-%012d", index),
                        kind: .project, ownerID: String(repeating: "a", count: 64),
                        name: String(repeating: "n", count: 10_000))
        }
        let scope = LinuxAuthorityCatalogScope.project(projectID: UUID(),
                                                       workspaceOwnerID: String(repeating: "a", count: 64))
        let fingerprint = LinuxAuthorityCatalogCursor.fingerprint(scope: scope,
                                                                 baseRevision: baseRevision, rows: rows)
        let page = try LinuxAuthorityCatalogPageBuilder.page(scope: scope, baseRevision: baseRevision,
                                                             fingerprint: fingerprint, rows: rows,
                                                             offset: 0, limit: 10)
        XCTAssertGreaterThan(page.environments.count, 0)
        XCTAssertLessThan(page.environments.count, 10)
        XCTAssertEqual(page.environments, Array(rows[0..<page.environments.count]))
        let reply = LinuxAuthorityReply(version: LinuxAuthorityWire.version,
                                        requestID: String(repeating: "\"", count: 64),
                                        outcome: .ok(.listPage(page)))
        let encoded = try XCTUnwrap(LinuxAuthorityWire.encodeReplyData(reply))
        XCTAssertLessThanOrEqual(encoded.count, LinuxAuthorityWire.maximumBytes)
        let next = try XCTUnwrap(page.nextCursor)
        XCTAssertEqual(try XCTUnwrap(LinuxAuthorityCatalogCursor.decode(next)).offset, page.environments.count)

        // The omitted remainder still pages without loss.
        var offset = page.environments.count
        var pages = 1
        while offset < rows.count {
            let remaining = try LinuxAuthorityCatalogPageBuilder.page(scope: scope, baseRevision: baseRevision,
                                                                      fingerprint: fingerprint, rows: rows,
                                                                      offset: offset, limit: 10)
            XCTAssertGreaterThan(remaining.environments.count, 0)
            XCTAssertEqual(remaining.environments, Array(rows[offset..<(offset + remaining.environments.count)]))
            offset += remaining.environments.count
            pages += 1
            XCTAssertLessThanOrEqual(pages, 10)
        }
        XCTAssertEqual(offset, rows.count)
    }

    func testPageBuilderRefusesARowThatCannotFitAtAll() throws {
        let rows = [metadataRow(id: "20000000-0000-4000-8000-000000000001",
                                kind: .project, ownerID: String(repeating: "b", count: 64),
                                name: String(repeating: "z", count: 70_000))]
        let scope = LinuxAuthorityCatalogScope.project(projectID: UUID(),
                                                       workspaceOwnerID: String(repeating: "b", count: 64))
        let fingerprint = LinuxAuthorityCatalogCursor.fingerprint(scope: scope, baseRevision: baseRevision, rows: rows)
        XCTAssertThrowsError(try LinuxAuthorityCatalogPageBuilder.page(
            scope: scope, baseRevision: baseRevision, fingerprint: fingerprint,
            rows: rows, offset: 0, limit: 1)) { error in
            XCTAssertEqual((error as? LinuxAuthorityError)?.code, .replyTooLarge)
        }
    }

    // MARK: - Frozen legacy wire + additive operation shape

    func testListPageOperationShapeIsAdditiveAndLegacyV1StaysFrozen() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try encoder.encode(LinuxAuthorityOperation.list), as: UTF8.self), #""list""#)
        XCTAssertEqual(String(decoding: try encoder.encode(LinuxAuthorityOperation.handshake), as: UTF8.self),
                       #""handshake""#)
        XCTAssertEqual(String(decoding: try encoder.encode(LinuxAuthorityOperation.listPage(.init())), as: UTF8.self),
                       #"{"listPage":{}}"#)
        XCTAssertEqual(String(decoding: try encoder.encode(LinuxAuthorityOperation.listPage(
            .init(projectID: "P", cursor: "v1.c.0", limit: 7))), as: UTF8.self),
                       #"{"listPage":{"cursor":"v1.c.0","limit":7,"projectID":"P"}}"#)

        // Strict decode: an unknown key inside the additive payload fails.
        XCTAssertThrowsError(try JSONDecoder().decode(LinuxAuthorityRequest.self, from: Data(
            #"{"version":1,"operation":{"listPage":{"limit":1,"page":2}}}"#.utf8))) { error in
            XCTAssertEqual(error as? LinuxAuthorityWireError, .unknownField("page"))
        }
        // Round-trip through the real envelope.
        let request = LinuxAuthorityRequest(version: 1, requestID: "r",
                                            operation: .listPage(.init(projectID: "P", cursor: nil, limit: 3)))
        let decodedRequest = try LinuxAuthorityWire.decodeRequest(try JSONEncoder().encode(request))
        XCTAssertEqual(decodedRequest, request)
    }

    func testListPageReplyKeepsOptionalKeysPresentAsNull() async throws {
        // Unscoped terminal page: projectID/workspaceOwnerID/nextCursor are
        // PRESENT nulls, not omitted keys (the frozen reply convention).
        let page = try await authority.listPage(.init(limit: 1))
        XCTAssertEqual(page.scope, "all")
        XCTAssertNil(page.projectID)
        XCTAssertNil(page.workspaceOwnerID)
        XCTAssertNil(page.nextCursor)

        let reply = await authority.exchange(pageRequest(limit: 1))
        let payload = try XCTUnwrap(successPage(reply))
        XCTAssertEqual(Set(payload.keys),
                       ["baseRevision", "environments", "nextCursor", "projectID",
                        "workspaceOwnerID", "scope", "total"])
        XCTAssertTrue(payload["nextCursor"] is NSNull)
        XCTAssertTrue(payload["projectID"] is NSNull)
        XCTAssertTrue(payload["workspaceOwnerID"] is NSNull)
        XCTAssertEqual(payload["baseRevision"] as? String, baseRevision)
        XCTAssertEqual(payload["total"] as? Int, 1, "only the shared record exists")
        XCTAssertEqual((payload["environments"] as? [[String: Any]])?.count, 1)

        // The typed reply round-trips.
        let decodedReply = try JSONDecoder().decode(LinuxAuthorityReply.self, from: reply)
        XCTAssertEqual(decodedReply, LinuxAuthorityReply(version: 1, requestID: "catalog-page",
                                                         outcome: .ok(.listPage(page))))
    }
}
