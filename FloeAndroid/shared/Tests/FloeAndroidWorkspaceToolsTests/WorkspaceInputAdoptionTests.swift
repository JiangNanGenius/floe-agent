// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeAndroidWorkspaceTools
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class WorkspaceInputAdoptionTests: XCTestCase {
    private var root: URL!
    private var hooks: TestHooks!
    private var workspace: String { root.appendingPathComponent("Workspace").path }

    override func setUpWithError() throws {
        root = try WorkspaceTestSupport.makeTempRoot(UUID().uuidString)
        hooks = TestHooks()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func fixture(ownerBudgets: WorkspaceTransferBudgets = .defaults, externalChange: Bool = true) throws
        -> (engine: WorkspaceTransferEngine, owner: String, input: String, index: Int64) {
        let engine = WorkspaceTransferEngine()
        XCTAssertTrue(engine.install(hooks: hooks.hooks(),
            transferRoot: root.appendingPathComponent("Transfers").path))
        try WorkspaceTestSupport.write("guest old", to: workspace + "/old.txt")
        let owner = try engine.openSession(binding: hooks.mint(runID: UUID(), conversationID: UUID(),
            workspaceID: UUID(), rootPath: workspace, budgets: ownerBudgets))
        _ = try engine.baselineBegin(sessionKey: owner)
        _ = try engine.baselineFinish(sessionKey: owner, appliedCount: 1, appliedBytes: 9)
        // A later snapshot must not rebase this already-owned path.
        if externalChange { try WorkspaceTestSupport.write("Core external update", to: workspace + "/old.txt") }
        try WorkspaceTestSupport.write("", to: workspace + "/new.txt")
        let input = try engine.openSession(binding: hooks.mint(runID: UUID(), conversationID: UUID(),
            workspaceID: UUID(), rootPath: workspace))
        let scan = try engine.baselineBegin(sessionKey: input)
        let count = try XCTUnwrap(scan["entryCount"] as? Int)
        for index in 0..<count {
            if try engine.baselineHeader(sessionKey: input, index: Int64(index))?["path"] as? String == "new.txt" {
                let data = try engine.baselineOpenData(sessionKey: input, index: Int64(index))
                close(data.fd)
                return (engine, owner, input, Int64(index))
            }
        }
        throw WorkspaceTransferError.malformed
    }

    private func stage(_ text: String, path: String, sequence: Int64,
                       engine: WorkspaceTransferEngine, owner: String) throws {
        let source = root.appendingPathComponent("Runtime/\(sequence).txt").path
        try WorkspaceTestSupport.write(text, to: source)
        let fd = open(source, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        _ = try engine.exportStage(sessionKey: owner, header: ["seq": sequence, "path": path,
            "kind": "file", "size": text.utf8.count, "mode": 420], dataFd: fd)
    }

    func testNewInputReturnsWithoutRebasingExistingExternalChanges() throws {
        let f = try fixture()
        XCTAssertEqual(try f.engine.adoptInput(sessionKey: f.owner,
            sourceSessionKey: f.input, index: f.index)["state"] as? String, "adopted")
        // Same exact receipt is idempotent while its source remains live.
        _ = try f.engine.adoptInput(sessionKey: f.owner, sourceSessionKey: f.input, index: f.index)
        _ = try f.engine.abort(sessionKey: f.input, reason: "input-transfer-complete")
        _ = try f.engine.exportBegin(sessionKey: f.owner)
        try stage("guest edited input", path: "new.txt", sequence: 1, engine: f.engine, owner: f.owner)
        try stage("guest old", path: "old.txt", sequence: 2, engine: f.engine, owner: f.owner)
        let result = try f.engine.exportFinish(sessionKey: f.owner)
        XCTAssertEqual(result["result"] as? String, "conflict")
        let conflicts = (result["preview"] as? [String: Any])?["conflicts"] as? [[String: Any]]
        XCTAssertEqual(conflicts?.compactMap { $0["path"] as? String }, ["old.txt"])
        XCTAssertEqual(try String(contentsOfFile: workspace + "/new.txt", encoding: .utf8), "guest edited input")
        XCTAssertEqual(try String(contentsOfFile: workspace + "/old.txt", encoding: .utf8), "Core external update")
    }

    func testNewInputWithoutExternalEditsReturnsAsSynced() throws {
        let f = try fixture(externalChange: false)
        _ = try f.engine.adoptInput(sessionKey: f.owner, sourceSessionKey: f.input, index: f.index)
        _ = try f.engine.abort(sessionKey: f.input, reason: "input-transfer-complete")
        _ = try f.engine.exportBegin(sessionKey: f.owner)
        try stage("guest edited input", path: "new.txt", sequence: 1, engine: f.engine, owner: f.owner)
        try stage("guest old", path: "old.txt", sequence: 2, engine: f.engine, owner: f.owner)
        XCTAssertEqual(try f.engine.exportFinish(sessionKey: f.owner)["result"] as? String, "synced")
        XCTAssertEqual(try String(contentsOfFile: workspace + "/new.txt", encoding: .utf8), "guest edited input")
    }

    func testCoreChangeAfterInputSnapshotStillConflicts() throws {
        let f = try fixture(externalChange: false)
        _ = try f.engine.adoptInput(sessionKey: f.owner, sourceSessionKey: f.input, index: f.index)
        try WorkspaceTestSupport.write("user later", to: workspace + "/new.txt")
        _ = try f.engine.exportBegin(sessionKey: f.owner)
        try stage("guest edited input", path: "new.txt", sequence: 1, engine: f.engine, owner: f.owner)
        try stage("guest old", path: "old.txt", sequence: 2, engine: f.engine, owner: f.owner)
        let result = try f.engine.exportFinish(sessionKey: f.owner)
        XCTAssertEqual(result["result"] as? String, "conflict")
        XCTAssertEqual(try String(contentsOfFile: workspace + "/new.txt", encoding: .utf8), "user later")
        let preview = result["preview"] as? [String: Any]
        XCTAssertFalse((preview?["conflicts"] as? [[String: Any]])?.isEmpty ?? true)
        let recovered = root.appendingPathComponent("Transfers/recovered/\(f.owner)")
        let artifacts = try FileManager.default.contentsOfDirectory(at: recovered, includingPropertiesForKeys: nil)
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(artifacts.first), encoding: .utf8), "guest edited input")
    }

    func testExistingOwnerPathCannotAdoptANewerCoreBaseline() throws {
        let f = try fixture()
        let oldIndex: Int64 = f.index == 0 ? 1 : 0
        XCTAssertThrowsError(try f.engine.adoptInput(sessionKey: f.owner,
            sourceSessionKey: f.input, index: oldIndex))
    }

    func testAbortedSourceAndInvalidIndicesCannotChangeOwnerBaseline() throws {
        let f = try fixture()
        XCTAssertThrowsError(try f.engine.adoptInput(sessionKey: f.owner, sourceSessionKey: f.input, index: -1))
        XCTAssertThrowsError(try f.engine.adoptInput(sessionKey: f.owner, sourceSessionKey: f.owner, index: 0))
        _ = try f.engine.abort(sessionKey: f.input, reason: "cancelled")
        XCTAssertThrowsError(try f.engine.adoptInput(sessionKey: f.owner,
            sourceSessionKey: f.input, index: f.index))
    }

    func testForeignWorkspaceCannotSupplyAnInput() throws {
        let f = try fixture()
        let other = root.appendingPathComponent("OtherProject").path
        try WorkspaceTestSupport.write("foreign", to: other + "/foreign.txt")
        let key = try f.engine.openSession(binding: hooks.mint(runID: UUID(), conversationID: UUID(),
            workspaceID: UUID(), rootPath: other))
        _ = try f.engine.baselineBegin(sessionKey: key)
        XCTAssertThrowsError(try f.engine.adoptInput(sessionKey: f.owner, sourceSessionKey: key, index: 0))
    }

    func testOwnerBudgetAndRevokedAuthorityRemainEnforced() throws {
        var budgets = WorkspaceTransferBudgets.defaults
        budgets.entryCount = 1
        let f = try fixture(ownerBudgets: budgets)
        XCTAssertThrowsError(try f.engine.adoptInput(sessionKey: f.owner,
            sourceSessionKey: f.input, index: f.index))
        hooks.runActive = false
        XCTAssertThrowsError(try f.engine.adoptInput(sessionKey: f.owner,
            sourceSessionKey: f.input, index: f.index))
    }
}
