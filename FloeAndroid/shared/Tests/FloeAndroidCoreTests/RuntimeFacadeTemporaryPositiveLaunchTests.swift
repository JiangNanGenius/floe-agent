// SPDX-License-Identifier: MPL-2.0
//
// RB-5 POSITIVE temporary launch + isolation tests. AUTHORED, NOT EXECUTED.
//
// Main correction (2026-10-19, after RB4 parent review): the future
// qualification path must prove a POSITIVE temporary engine launch through
// the repaired run-assembly producer (job-047bee7a3eff4941, which preserves
// the public `start(query:…bundleOverride:)` seam intent) and true ordinary
// DB/FS isolation — an accepted typed rejection is NEVER proof that a
// feature works. These tests therefore assert the positive shape the
// composition must satisfy, over the ORIGINAL ephemeral stores (the SAME
// run-store instance shared by the bundle and the launcher), plus exact
// fail-closed identity checks and zero filesystem/DB drift while temporary.
import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloeTools
import FloePersistence
@testable import FloeAndroidCore

final class RuntimeFacadeTemporaryPositiveLaunchTests: XCTestCase {
    private var fixture: TemporaryDomainFixture!

    override func setUp() async throws {
        fixture = try await TemporaryDomainFixture.make()
    }

    override func tearDown() async throws {
        await fixture.teardown()
    }

    // MARK: - The ORIGINAL ephemeral launcher applies into the SAME stores

    func testEphemeralLauncherAppliesIntoTheSameSessionStoreInstances() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        let authority = await fixture.domain.authority(conversationID: cid,
                                                       incarnation: inc)!
        let stores = authority.stores
        // Positive apply through the ORIGINAL EphemeralRunLaunchStore —
        // the exact path a repaired temporary engine launch rides: the run
        // header, the user message and the initial status event land in
        // the session's own RAM stores, the SAME instances the bundle
        // carries (identity through `===` on the actor references).
        let runID = UUID()
        let prepared = try await stores.launches.prepare(RunLaunchRequest(
            newConversationID: cid,
            runID: runID,
            goal: "positive turn canary",
            conversationMode: "chat",
            messageRole: "user",
            startedAt: Date()))
        XCTAssertEqual(prepared.conversation.id, cid)
        XCTAssertEqual(prepared.run.id, runID)
        // The apply went into the bundle's run store — not a parallel one.
        let observed = try await stores.runs.run(id: runID)
        XCTAssertNotNil(observed)
        XCTAssertEqual(observed?.goal, "positive turn canary")
        let events = try await stores.runs.events(runID: runID)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.sequence, 1)
        // Same for the conversation store: the user message with its text
        // part is readable through the bundle instance.
        let messages = try await stores.conversations.messages(conversationID: cid)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, "user")
        let parts = try await stores.conversations.parts(messageID: messages[0].id)
        XCTAssertEqual(parts.first?.text, "positive turn canary")
        // The virtual private workspace record exists ONLY as a value:
        // nothing durable was written for it.
        XCTAssertEqual(prepared.workspace.kind, WorkspaceKind.privateTask)
        let counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["conversations"], 0)
        XCTAssertEqual(counts["runs"], 0)
        XCTAssertEqual(counts["workspaces"], 0)
    }

    func testEphemeralLauncherRefusesForeignHostedIdentityFailClosed() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        let authority = await fixture.domain.authority(conversationID: cid,
                                                       incarnation: inc)!
        do {
            _ = try await authority.stores.launches.prepare(RunLaunchRequest(
                newConversationID: UUID(),          // foreign identity
                runID: UUID(),
                goal: "smuggle"))
            XCTFail("a foreign launch identity must fail closed")
        } catch let error as FloeError {
            // The ORIGINAL validation message, not a wrapper invention.
            XCTAssertTrue(String(describing: error)
                .contains("Launch identity does not match"))
        }
    }

    // MARK: - The domain hands the repaired seam the exact positive shape

    func testDomainHandsTheRunLaneTheExactPositiveTemporaryShape() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        let reply = await fixture.domain.temporaryLaunch(
            conversationID: cid, incarnation: inc,
            correlation: "positive-shape", receipt: nil,
            goal: "what is the weather", mode: "chat",
            preferredModelID: nil, attachmentCount: 0,
            stagedAttachmentHandles: 0)
        // POSITIVE: the controlled port launched a real run id and the
        // domain registered it (not a rejection being proved).
        guard case .launched(let runID) = reply else {
            return XCTFail("temporary launch must succeed against the seam")
        }
        let launch = fixture.port.recordedLaunches.last!
        XCTAssertEqual(launch.request.conversationID, cid)
        XCTAssertEqual(launch.request.incarnation, inc)
        XCTAssertEqual(launch.request.epoch, fixture.epoch)
        XCTAssertEqual(launch.request.mode, "chat")
        XCTAssertTrue(launch.request.stores.isTemporary)
        // SAME-instance invariant (Main correction): proved POSITIVELY in
        // `testEphemeralLauncherAppliesIntoTheSameSessionStoreInstances`
        // and `testMultiTurnFollowUpRidesTheSameSessionAcrossLaunches` —
        // observable mutation through the bundle's own run store, not
        // pointer tricks and not a rejection proof.
        // The frozen ceiling is positive too: web.fetch present when the
        // search providers are configured.
        XCTAssertTrue(launch.request.frozenToolCeiling.contains("web.fetch"))
        XCTAssertTrue(launch.request.frozenToolCeiling.contains("web.search"))
        // Registration bookkeeping observable through the port AND status.
        let liveRun = await fixture.port.hasLiveTemporaryRun(
            conversationID: cid, incarnation: inc, runID: runID)
        XCTAssertTrue(liveRun)
        let status = await fixture.domain.status()
        XCTAssertEqual(status.ownedRunCount, 1)
        // Keep with the live run tail preserves it (original once-only
        // semantics), proving the positive path feeds the real stores:
        _ = try await fixture.seedTurn(conversationID: cid, runID: runID,
                                       canary: "TAIL-POSITIVE")
        let keepReply = await fixture.domain.keep(
            conversationID: cid, incarnation: inc, idempotencyKey: UUID(),
            receipt: nil, correlation: "kp")
        guard case .mutationAccepted(let detail, _) = keepReply.outcome else {
            return XCTFail("keep after a positive launch must commit: \(keepReply.outcome)")
        }
        XCTAssertEqual(detail["keep"], "committed")
        let durableEvents = try await fixture.durableRuns.events(runID: runID)
        XCTAssertGreaterThanOrEqual(durableEvents.count, 2)  // frozen + tail
    }

    func testMultiTurnFollowUpRidesTheSameSessionAcrossLaunches() async throws {
        // Every turn of one session reaches the run lane with the SAME
        // hosted id + incarnation and the SAME store instances; the second
        // launch sees the first turn's RAM history (positive continuation,
        // no ordinary fallback, no new session).
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        let first = await fixture.domain.temporaryLaunch(
            conversationID: cid, incarnation: inc,
            correlation: "t1", receipt: nil, goal: "first", mode: "chat",
            preferredModelID: nil, attachmentCount: 0, stagedAttachmentHandles: 0)
        guard case .launched(let firstRun) = first else { return XCTFail("t1") }
        _ = try await fixture.seedTurn(conversationID: cid, runID: firstRun,
                                       canary: "TURN-1")
        let second = await fixture.domain.temporaryLaunch(
            conversationID: cid, incarnation: inc,
            correlation: "t2", receipt: nil, goal: "second", mode: "chat",
            preferredModelID: nil, attachmentCount: 0, stagedAttachmentHandles: 0)
        guard case .launched(let secondRun) = second else { return XCTFail("t2") }
        XCTAssertNotEqual(firstRun, secondRun)
        let l1 = fixture.port.recordedLaunches[0]
        let l2 = fixture.port.recordedLaunches[1]
        XCTAssertEqual(l1.request.conversationID, l2.request.conversationID)
        XCTAssertEqual(l1.request.incarnation, l2.request.incarnation)
        // Store identity is proven by observable mutation (the first
        // turn's header is readable through the SECOND request's store
        // instance — they are the same objects):
        // SAME store instances (identity), and the first turn's header is
        // observable through the SECOND request's store reference — the
        // positive same-session continuation proof. (The controlled port
        // does not write a second header; the durable run lane does.)
        XCTAssertEqual(ObjectIdentifier(l1.request.stores.runs),
                       ObjectIdentifier(l2.request.stores.runs))
        XCTAssertEqual(ObjectIdentifier(l1.request.stores.conversations),
                       ObjectIdentifier(l2.request.stores.conversations))
        let runs = try await l2.request.stores.runs.runs(conversationID: cid)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.id, firstRun)
        let status = await fixture.domain.status()
        XCTAssertEqual(status.ownedRunCount, 2)
        let counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["runs"], 0)
    }

    // MARK: - Ordinary DB/FS isolation across the whole temporary flow

    func testTemporaryFlowLeavesNoFilesystemOrDatabaseDrift() async throws {
        let before = try directoryListing(fixture.root)
        let beforeCounts = try await fixture.durableCounts()
        XCTAssertEqual(beforeCounts.values.allSatisfy { $0 == 0 }, true,
                       "a fresh generation owns an empty business database")
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        _ = try await fixture.seedTurn(conversationID: cid, canary: "FS")
        _ = await fixture.domain.temporaryLaunch(
            conversationID: cid, incarnation: inc,
            correlation: "fs", receipt: nil, goal: "g", mode: "chat",
            preferredModelID: nil, attachmentCount: 0,
            stagedAttachmentHandles: 0)
        _ = TemporaryDomainFacade.noteHostLifecycleHint(.background,
                                                        epoch: fixture.epoch)
        _ = TemporaryDomainFacade.noteHostLifecycleHint(.locked,
                                                        epoch: fixture.epoch)
        _ = await fixture.domain.end(conversationID: cid, incarnation: inc)
        let after = try directoryListing(fixture.root)
        let afterCounts = try await fixture.durableCounts()
        // The temporary session wrote NO new file anywhere under the owner
        // root: no disk snapshot, no draft persistence, no diagnostic or
        // fixture artifact, no log copy of the transcript.
        XCTAssertEqual(Set(after), Set(before))
        XCTAssertEqual(afterCounts, beforeCounts)
        XCTAssertEqual(afterCounts["message_fts"], 0)
    }

    private func directoryListing(_ root: URL) throws -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var paths: [String] = []
        for case let url as URL in enumerator {
            paths.append(url.path.replacingOccurrences(of: root.path + "/",
                                                       with: ""))
        }
        return paths
    }

    // MARK: - No ordinary fallback / no RAM fake credentials

    func testTemporaryPresentationNeverReachesTheOrdinaryDurablePath() async throws {
        // The frozen-matrix rule "a temporary presentation through the
        // ordinary wire surface is structurally impossible" is proved
        // POSITIVELY here: the only launch that touches the session stores
        // is the port-shaped temporary one; the durable stores stay empty,
        // and the hosted id can never be resolved by the durable store.
        let (cid, _, _, _, _) = try await fixture.startedSession()
        _ = await fixture.domain.temporaryLaunch(
            conversationID: cid, incarnation: fixture.currentIncarnation()!,
            correlation: "iso", receipt: nil, goal: "g", mode: "chat",
            preferredModelID: nil, attachmentCount: 0,
            stagedAttachmentHandles: 0)
        let durableRecord = try await fixture.durableConversations
            .conversation(id: cid)
        XCTAssertNil(durableRecord)          // no ordinary row for the id
        let durableRuns = try await fixture.durableRuns
            .runs(conversationID: cid)
        XCTAssertTrue(durableRuns.isEmpty)
        // And the census stays zero (same file, same instant).
        let counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["runs"], 0)
    }
}
