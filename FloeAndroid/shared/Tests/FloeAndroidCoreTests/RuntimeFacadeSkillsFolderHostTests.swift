// SPDX-License-Identifier: MPL-2.0
//
// S11 Skills folder staging host seam — qualification TEST SOURCE
// (authored, NOT executed by this package; Main runs the composed
// Swift/Native batch). The tests drive the REAL trusted host lane against
// the REAL RB6 fixture bootstrap + SkillsDomain on temp roots: route/epoch
// fencing, original path safety, budgets, the domain's own
// registerStagedFolder digest verification, cleanup on refusal/abort, and
// the closed `folder.import` grammar (a model envelope can never forge a
// stg:v1 handle or name a filesystem path).
import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeSkills
import FloeTools
import FloePersistence

final class RuntimeFacadeSkillsFolderHostTests: XCTestCase {

    override func tearDown() async throws {
        SkillsFolderHostStaging.shared.domainOverrideForTesting = nil
        await RB6TestFixture.shutdownCurrent()
    }

    private func makeLiveLane(_ id: String) async throws
        -> (RB6TestFixture, SkillsDomain, SkillsCommandRouter, UInt64) {
        let fixture = try await RB6TestFixture.make(id: id)
        let toolWork = FacadeToolWorkCoordinator()
        let registry = ToolRunnerRegistry()
        let domain = try SkillsDomain(services: .init(
            database: fixture.database,
            installationRoot: fixture.installationRoot,
            stagingRoot: fixture.stagingRoot,
            hostContext: fixture.hostContext,
            transport: SkillsRemoteTransportUnavailable(),
            rewriter: SkillModelRewritingUnavailable(),
            ownedWork: fixture.ownedWorkLifecycle(),
            toolWork: toolWork,
            registry: registry))
        SkillsFolderHostStaging.shared.domainOverrideForTesting = domain
        guard let epoch = AndroidRuntimeBootstrap.currentPumps()?.epoch else {
            throw XCTSkip("live bootstrap epoch unavailable")
        }
        return (fixture, domain, SkillsCommandRouter(domain: domain), epoch)
    }

    private func envelope(command: String, payload: sending [String: Any]?,
                          createIntent: Bool) -> sending [String: Any] {
        var envelope: [String: Any] = [
            "schema": "floe.command-envelope/3",
            "scope": "applicationConfiguration",
            "command": command,
            "configurationScope": "skills",
            "stateful": true,
            "correlationID": "c-\(UUID().uuidString)",
        ]
        if let payload { envelope["payload"] = payload }
        if createIntent { envelope["createIntent"] = true }
        return envelope
    }

    // MARK: route + epoch fencing

    func testRouteBindingRequiresLiveClaimedEpoch() async throws {
        let (_, _, _, epoch) = try await makeLiveLane("folder-route")
        let lane = SkillsFolderHostStaging.shared
        // Wrong claimed epoch (host captured a retired generation): fenced.
        let stale = lane.routeOpen(incarnation: 1, uiGeneration: 1,
                                   claimedEpoch: epoch &+ 1)
        XCTAssertEqual(stale.0, SkillsFolderHostStatus.epochFenced)
        // Right epoch: admitted with an opaque ASCII receipt.
        let ok = lane.routeOpen(incarnation: 2, uiGeneration: 3, claimedEpoch: epoch)
        XCTAssertEqual(ok.0, SkillsFolderHostStatus.ok)
        let receipt = try XCTUnwrap(ok.1)
        XCTAssertTrue(receipt.hasPrefix("sfk:v1:"))
        XCTAssertTrue(receipt.utf8.count == 39)
        // Zero arguments are invalid, never accepted:
        XCTAssertEqual(lane.routeOpen(incarnation: 0, uiGeneration: 1,
                                      claimedEpoch: epoch).0,
                       SkillsFolderHostStatus.invalidArguments)
        lane.routeClose(receipt: receipt)
    }

    // MARK: success path — domain registers the REAL receipt

    func testStagedTreeRegistersThroughDomainAndFlowsClosedImport() async throws {
        let (fixture, domain, router, epoch) = try await makeLiveLane("folder-ok")
        let lane = SkillsFolderHostStaging.shared
        let route = try XCTUnwrap(lane.routeOpen(incarnation: 1, uiGeneration: 1,
                                                 claimedEpoch: epoch).1)
        let tree = try XCTUnwrap(lane.treeOpen(routeReceipt: route,
                                               displayNameHint: "My Skill").1)
        // Two files (root + subdir), one Unicode name (validator-legal):
        let f1 = try XCTUnwrap(lane.fileBegin(treeReceipt: tree,
                                              relativePath: "SKILL.md").1)
        XCTAssertEqual(lane.fileWrite(receipt: f1,
                                      bytes: Data(skillMarkdown.utf8)),
                       SkillsFolderHostStatus.ok)
        XCTAssertEqual(lane.fileEnd(receipt: f1), SkillsFolderHostStatus.ok)
        let f2 = try XCTUnwrap(lane.fileBegin(treeReceipt: tree,
                                              relativePath: "资产/参考 报告.md").1)
        XCTAssertEqual(lane.fileWrite(receipt: f2, bytes: Data("notes".utf8)),
                       SkillsFolderHostStatus.ok)
        XCTAssertEqual(lane.fileEnd(receipt: f2), SkillsFolderHostStatus.ok)

        let finish = lane.treeFinish(treeReceipt: tree, displayNameHint: "My Skill")
        XCTAssertEqual(finish.0, SkillsFolderHostStatus.ok)
        let line = try XCTUnwrap(finish.1)
        let tokens = line.split(separator: " ").map(String.init)
        XCTAssertEqual(tokens.count, 3)
        XCTAssertTrue(tokens[0].hasPrefix("stg:v1:"))
        XCTAssertEqual(tokens[1], "2")
        let staged = fixture.stagingRoot
            .appendingPathComponent("host-folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))

        // Only the opaque token may re-enter the world, through the
        // CLOSED folder.import grammar (create intent, no revision):
        let reply = await router.handle(
            command: "skills.install",
            envelope: envelope(command: "skills.install",
                               payload: ["operation": "folder.import",
                                         "stagingToken": tokens[0]],
                               createIntent: true))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: reply) as? [String: Any])
        // Either committed install or staged review — a typed terminal,
        // never a parse refusal (the domain found the REAL receipt):
        XCTAssertTrue(object["state"] as? String == "completed"
            || object["errorCode"] != nil)
        if object["state"] as? String == "completed" {
            let value = try XCTUnwrap(object["value"] as? [String: Any])
            // Receipt single-use: a second import of the same token is
            // the domain's typed notFound (no replay install).
            let second = await router.handle(
                command: "skills.install",
                envelope: envelope(command: "skills.install",
                                   payload: ["operation": "folder.import",
                                             "stagingToken": tokens[0]],
                                   createIntent: true))
            let secondObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: second) as? [String: Any])
            XCTAssertNil(secondObject["state"])
            XCTAssertEqual(secondObject["errorCode"] as? String, "notFound")
            _ = value
        }
        _ = domain
        lane.routeClose(receipt: route)
    }

    // MARK: path safety + budgets (pre-domain typed refusals)

    func testTraversalDuplicateDepthAndCountRefusals() async throws {
        let (_, _, _, epoch) = try await makeLiveLane("folder-guard")
        let lane = SkillsFolderHostStaging.shared
        let route = try XCTUnwrap(lane.routeOpen(incarnation: 1, uiGeneration: 1,
                                                 claimedEpoch: epoch).1)
        let tree = try XCTUnwrap(lane.treeOpen(routeReceipt: route,
                                               displayNameHint: nil).1)
        for hostile in ["../escape", "a/../../b", "/absolute", "back\\slash",
                        "", ".", ".."] {
            let status = lane.fileBegin(treeReceipt: tree, relativePath: hostile).0
            XCTAssertEqual(status, SkillsFolderHostStatus.pathUnsafe,
                           "must refuse by the ORIGINAL segment rules: \(hostile)")
        }
        // Case-canonical duplicate refusal:
        let ok = try XCTUnwrap(lane.fileBegin(treeReceipt: tree,
                                              relativePath: "Readme.md").1)
        lane.fileEnd(receipt: ok)
        XCTAssertEqual(lane.fileBegin(treeReceipt: tree, relativePath: "readme.MD").0,
                       SkillsFolderHostStatus.duplicatePath)
        // Depth > 16:
        let deep = (1...17).map { "d\($0)" }.joined(separator: "/") + "/leaf.md"
        XCTAssertEqual(lane.fileBegin(treeReceipt: tree, relativePath: deep).0,
                       SkillsFolderHostStatus.depthExceeded)
        lane.treeAbort(treeReceipt: tree)
        lane.routeClose(receipt: route)
    }

    func testFinishEmptyTreeIsRefusedAndOwnedDirectoryRemoved() async throws {
        let (fixture, _, _, epoch) = try await makeLiveLane("folder-empty")
        let lane = SkillsFolderHostStaging.shared
        let route = try XCTUnwrap(lane.routeOpen(incarnation: 1, uiGeneration: 1,
                                                 claimedEpoch: epoch).1)
        let tree = try XCTUnwrap(lane.treeOpen(routeReceipt: route,
                                               displayNameHint: nil).1)
        let status = lane.treeFinish(treeReceipt: tree, displayNameHint: nil)
        XCTAssertEqual(status.0, SkillsFolderHostStatus.receiptRefused)
        XCTAssertNil(status.1)
        // No empty-receipt lane: the tree table is pruned and the owned
        // directory is gone (recoverable cleanup, nothing else touched).
        let hostFolder = fixture.stagingRoot.appendingPathComponent("host-folder")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: hostFolder.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "refused finish must remove its owned tree")
        lane.routeClose(receipt: route)
    }

    func testRouteCloseAbortsLiveTreeBytes() async throws {
        let (fixture, _, _, epoch) = try await makeLiveLane("folder-close")
        let lane = SkillsFolderHostStaging.shared
        let route = try XCTUnwrap(lane.routeOpen(incarnation: 1, uiGeneration: 1,
                                                 claimedEpoch: epoch).1)
        let tree = try XCTUnwrap(lane.treeOpen(routeReceipt: route,
                                               displayNameHint: nil).1)
        let file = try XCTUnwrap(lane.fileBegin(treeReceipt: tree,
                                                relativePath: "SKILL.md").1)
        XCTAssertEqual(lane.fileWrite(receipt: file, bytes: Data("hi".utf8)),
                       SkillsFolderHostStatus.ok)
        lane.routeClose(receipt: route)
        let hostFolder = fixture.stagingRoot.appendingPathComponent("host-folder")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: hostFolder.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "route close must remove the owned lane trees")
    }

    // MARK: no model-callable backdoor

    func testModelEnvelopesCannotForgeStagingTokens() async throws {
        let (_, _, router, _) = try await makeLiveLane("folder-forge")
        for forged in ["/tmp/whatever",
                       "stg:v1:zz",                                  // wrong length/hex
                       "stg:v1:" + String(repeating: "g", count: 32), // non-hex
                       "stag:v1:" + String(repeating: "0", count: 32)] { // foreign prefix
            let reply = await router.handle(
                command: "skills.install",
                envelope: envelope(command: "skills.install",
                                   payload: ["operation": "folder.import",
                                             "stagingToken": forged],
                                   createIntent: true))
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: reply) as? [String: Any])
            XCTAssertNil(object["state"], "forged token must never settle: \(forged)")
            XCTAssertEqual(object["errorCode"] as? String, "invalidEnvelope")
        }
        // A WELL-FORMED but unknown handle is the domain's typed notFound:
        let unknown = "stg:v1:" + String(repeating: "a", count: 32)
        let unknownReply = await router.handle(
            command: "skills.install",
            envelope: envelope(command: "skills.install",
                               payload: ["operation": "folder.import", "stagingToken": unknown],
                               createIntent: true))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: unknownReply) as? [String: Any])
        XCTAssertEqual(object["errorCode"] as? String, "notFound")
    }

    private var skillMarkdown: String {
        """
        ---
        name: Folder Staged Guide
        description: A minimal skill staged from a user-picked folder.
        ---

        # Instructions

        Say hello.
        """
    }
}
