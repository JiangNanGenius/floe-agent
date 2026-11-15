// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameIDEBridge

@MainActor private final class ExistingIDEHost: GameIDEProjectHost {
    var pin: GameIDEWorkspacePin?
    var context: GameProjectContext
    var opened: [GameIDEOpenRequest] = []
    var launches: [GameIDEProjectRunRequest] = []
    var stopped: [UUID] = []
    var snapshotCount = 0
    var changeSecondSnapshot = false
    var holdFirstLaunch = false
    var continuation: CheckedContinuation<Void,Never>?
    init(pin: GameIDEWorkspacePin, context: GameProjectContext) { self.pin=pin; self.context=context }
    func currentWorkspace() -> GameIDEWorkspacePin? { pin }
    func open(_ request: GameIDEOpenRequest) throws { opened.append(request) }
    func snapshot(_ workspace: GameIDEWorkspacePin) async throws -> GameProjectContext {
        snapshotCount += 1
        if changeSecondSnapshot && snapshotCount == 2 {
            context = try .init(projectID: context.projectID, owner: context.owner,
                rootURL: context.rootURL, savedRevision: "changed-by-git", environmentID: context.environmentID)
        }
        return context
    }
    func launch(_ request: GameIDEProjectRunRequest) async throws {
        launches.append(request)
        if holdFirstLaunch && launches.count == 1 { await withCheckedContinuation { continuation=$0 } }
    }
    func stop(requestID: UUID) async { stopped.append(requestID) }
    func resume() { continuation?.resume(); continuation=nil }
}

@MainActor final class IDEProjectRunTests: XCTestCase {
    private func fixture() throws -> (URL, ExistingIDEHost, GameIDEProjectExtension) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("game-ide-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id=UUID()
        let context=try GameProjectContext(projectID:id, owner:.space(recordID:id), rootURL:root,
                                            savedRevision:"saved", environmentID:"existing-project-environment")
        let pin=try GameIDEWorkspacePin(workspaceID:UUID(), context:context)
        let host=ExistingIDEHost(pin:pin, context:context)
        return (root,host,GameIDEProjectExtension(workspace:pin,host:host))
    }
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for:.milliseconds(1))
        }
        throw GameIDEBridgeError.superseded
    }
    func testFilesCodeAndGitOpenTheSameExistingWorkspace() throws {
        let (root,host,game)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        try game.open(.files)
        try game.open(.code(GameRelativePath("src/game.lua")))
        try game.open(.sourceControl)
        XCTAssertEqual(host.opened.map(\.workspace),[game.workspace,game.workspace,game.workspace])
        XCTAssertEqual(host.opened.map(\.destination),[.files,.code(try GameRelativePath("src/game.lua")),.sourceControl])
        XCTAssertTrue(host.launches.isEmpty)
    }
    func testWholeProjectRunUsesAllSavedBuffersAndLeavesGitUntouched() async throws {
        let (root,host,game)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let git=root.appendingPathComponent(".git");try FileManager.default.createDirectory(at:git,withIntermediateDirectories:true)
        let index=Data("existing staged index must stay unchanged".utf8)
        try index.write(to:git.appendingPathComponent("index"))
        let extensionAction=game.ideRunExtension(engine:.godot, gameRoot:try GameRelativePath("games/platformer"))
        try await extensionAction.run {
            let a=Data("new main".utf8),b=Data("new scene".utf8)
            do {
                try a.write(to:root.appendingPathComponent("main.gd"))
                try b.write(to:root.appendingPathComponent("main.tscn"))
                host.context=try .init(projectID:host.context.projectID,owner:host.context.owner,rootURL:root,
                    savedRevision:GameDigest.sha256(a+b),environmentID:host.context.environmentID)
                return true
            } catch { return false }
        }
        let request=try XCTUnwrap(host.launches.first)
        XCTAssertEqual(request.context.savedRevision,GameDigest.sha256(Data("new mainnew scene".utf8)))
        XCTAssertEqual(request.gameRoot?.value,"games/platformer")
        XCTAssertEqual(request.engine,.godot)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("main.gd")),Data("new main".utf8))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("main.tscn")),Data("new scene".utf8))
        XCTAssertEqual(try Data(contentsOf:git.appendingPathComponent("index")),index)
        await extensionAction.stop()
        XCTAssertEqual(host.stopped,[request.id])
    }
    func testUnresolvedBufferConflictNeverLaunches() async throws {
        let (root,host,game)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        do { try await game.run(engine:.phaser,saveAllSurfaces:{false});XCTFail("unsaved buffers must block") }
        catch { XCTAssertEqual(error as? GameIDEBridgeError,.unsavedChanges) }
        XCTAssertTrue(host.launches.isEmpty)
        XCTAssertEqual(host.snapshotCount,0)
    }
    func testWorkspaceSwitchDuringSaveCannotRedirectGameOrGit() async throws {
        let (root,host,game)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        do {
            try await game.run(engine:.phaser,saveAllSurfaces:{host.pin=nil;return true})
            XCTFail("workspace switch must fence dispatch")
        } catch { XCTAssertEqual(error as? GameIDEBridgeError,.workspaceChanged) }
        XCTAssertTrue(host.launches.isEmpty)
        XCTAssertThrowsError(try game.open(.sourceControl))
    }
    func testGitRevisionChangeDuringPreparationCannotRunOldSnapshot() async throws {
        let (root,host,game)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        host.changeSecondSnapshot=true
        do { try await game.run(engine:.phaser,saveAllSurfaces:{true});XCTFail("new checkout must fence old snapshot") }
        catch { XCTAssertEqual(error as? GameProjectError,.contextChanged(.revision)) }
        XCTAssertTrue(host.launches.isEmpty)
    }
    func testLateOldLaunchCleanupStopsOnlyItsOwnedRequest() async throws {
        let (root,host,game)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        host.holdFirstLaunch=true
        let first=Task{try await game.run(engine:.phaser,saveAllSurfaces:{true})}
        try await waitUntil{host.continuation != nil}
        await game.stop()
        // Stop reaches the suspended launch immediately. If it still returns
        // a late job, a second ID-scoped cleanup must leave the newer run alone.
        XCTAssertEqual(host.stopped,[host.launches[0].id])
        try await game.run(engine:.phaser,saveAllSurfaces:{true})
        let newer=try XCTUnwrap(host.launches.last)
        host.resume()
        do { try await first.value;XCTFail("late run must be fenced") }
        catch { XCTAssertEqual(error as? GameIDEBridgeError,.superseded) }
        XCTAssertEqual(host.stopped,[host.launches[0].id,host.launches[0].id])
        XCTAssertFalse(host.stopped.contains(newer.id))
        await game.stop()
        XCTAssertEqual(host.stopped.last,newer.id)
    }
}
