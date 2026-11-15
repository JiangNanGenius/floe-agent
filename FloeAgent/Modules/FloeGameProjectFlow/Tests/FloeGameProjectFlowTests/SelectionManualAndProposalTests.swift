// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameStarterKit
@testable import FloeGameProjectFlow

/// Regressions for the name-only creation, unknown-package identification and
/// assistant proposal path. They use only the real repository, discovery,
/// inspector, catalog and selection store.
final class SelectionManualAndProposalTests: XCTestCase {
    private func unknownFiles() -> [String: Data] {
        [
            "README.txt": Data("A package with no recognized engine marker".utf8),
            "assets/texture.bin": Data([0, 1, 2, 255]),
            "docs/manual.txt": Data("keep every unknown file".utf8)
        ]
    }

    private func nestedFiles() -> [String: Data] {
        [
            "Web/package.json": Data("{\"dependencies\":{\"phaser\":\"3.90.0\"}}".utf8),
            "Web/index.html": Data("<!doctype html>".utf8),
            "Legacy/Game.rvproj2": Data("VXAce".utf8),
            "Unknown/readme.txt": Data("unknown nested content".utf8)
        ]
    }

    func testUnknownPackageNeedsManualAcknowledgementAndPersistsUnverified() async throws {
        try await withSelectionWorkspace { workspace in
            let result = try await workspace.importFiles(unknownFiles())
            XCTAssertEqual(result.snapshot.state, .unresolved)
            XCTAssertNil(result.snapshot.selectedEngine)
            XCTAssertFalse(result.snapshot.isManualUnverified)
            XCTAssertNil(result.snapshot.runSelection)
            XCTAssertTrue(result.snapshot.unrecognizedRoots.contains {
                $0.root == nil && $0.engines.isEmpty
            })
            let noRecord = try await workspace.storedRecord(context: result.context)
            XCTAssertNil(noRecord)

            do {
                _ = try await workspace.coordinator.selectManual(
                    root: nil, engine: .godot, context: result.context,
                    acknowledgingUnverified: false)
                XCTFail("manual selection without user acknowledgement was accepted")
            } catch let error as GameProjectFlowError {
                XCTAssertEqual(error, .manualSelectionNotAcknowledged)
            }
            let stillNoRecord = try await workspace.storedRecord(context: result.context)
            XCTAssertNil(stillNoRecord)

            let manual = try await workspace.coordinator.selectManual(
                root: nil, engine: .godot, context: result.context,
                acknowledgingUnverified: true)
            XCTAssertEqual(manual.state, .confirmed)
            XCTAssertEqual(manual.selectionSource, .explicit)
            XCTAssertEqual(manual.selectedEngine, .godot)
            XCTAssertEqual(manual.selectionVerification, .manualUnverified)
            XCTAssertTrue(manual.isManualUnverified)
            XCTAssertTrue(manual.persisted)
            XCTAssertNil(manual.runSelection,
                         "manual evidence must not unlock run/build")
            XCTAssertTrue(manual.ambiguities.contains {
                if case .manualSelectionUnverified(_, .godot) = $0 { return true }
                return false
            })

            let stored = try await workspace.storedRecord(context: result.context)
            XCTAssertEqual(stored?.selectedEngine, .godot)
            XCTAssertEqual(stored?.verification, .manualUnverified)

            let restored = try await workspace.coordinator.refresh(
                project: result.project, context: result.context)
            XCTAssertEqual(restored.state, .confirmed)
            XCTAssertEqual(restored.selectionSource, .restored)
            XCTAssertEqual(restored.selectionVerification, .manualUnverified)
            XCTAssertNil(restored.runSelection)

            // A later real marker upgrades the same choice to evidence-backed.
            let committed = try await workspace.repository.commit(
                workspace.projectID, owner: workspace.owner,
                expectedRevision: result.context.savedRevision,
                changes: [.write(try GameRelativePath("project.godot"),
                                 Data("config_version=5\n".utf8))])
            let upgradedContext = try await workspace.context()
            XCTAssertEqual(upgradedContext.savedRevision, committed.revision)
            let upgraded = try await workspace.coordinator.refresh(
                project: committed, context: upgradedContext)
            XCTAssertEqual(upgraded.state, .confirmed)
            XCTAssertEqual(upgraded.selectedEngine, .godot)
            XCTAssertEqual(upgraded.selectionVerification, .evidenceMatched)
            XCTAssertEqual(upgraded.runSelection?.engine, .godot)
            let upgradedRecord = try await workspace.storedRecord(
                context: upgradedContext)
            XCTAssertEqual(upgradedRecord?.verification, .evidenceMatched)
            XCTAssertEqual(upgradedRecord?.baseRevision, committed.revision)
        }
    }

    func testManualSelectionRejectsEmptyProjectAndMissingRoot() async throws {
        try await withSelectionWorkspace { workspace in
            let empty = try await workspace.createEmpty()
            do {
                _ = try await workspace.coordinator.selectManual(
                    root: nil, engine: .godot, context: empty.1,
                    acknowledgingUnverified: true)
                XCTFail("an empty project accepted a manual selection")
            } catch let error as GameProjectFlowError {
                XCTAssertEqual(error, .emptyProjectSelection)
            }
        }
        try await withSelectionWorkspace { workspace in
            let imported = try await workspace.importFiles(unknownFiles())
            let missing = try GameRelativePath("Missing")
            do {
                _ = try await workspace.coordinator.selectManual(
                    root: missing, engine: .godot, context: imported.context,
                    acknowledgingUnverified: true)
                XCTFail("a missing root was accepted")
            } catch let error as GameProjectFlowError {
                XCTAssertEqual(error, .rootNotAvailable(missing))
            }
        }
    }

    func testRecognizedProposalIsAdvisoryUntilTheUserConfirmsIt() async throws {
        try await withSelectionWorkspace { workspace in
            let result = try await workspace.importFiles(nestedFiles())
            XCTAssertEqual(result.snapshot.state, .ambiguous)
            let noRecord = try await workspace.storedRecord(context: result.context)
            XCTAssertNil(noRecord)
            let web = try GameRelativePath("Web")

            let proposal = try await workspace.coordinator.proposeSelection(
                root: web, engine: .phaser,
                evidencePaths: [try GameRelativePath("Web/package.json")],
                rationale: "The Web folder contains a Phaser dependency.",
                generatedBy: "fixture-assistant", context: result.context)
            XCTAssertEqual(proposal.verification, .evidenceMatched)
            XCTAssertFalse(proposal.isManualUnverified)
            XCTAssertEqual(proposal.selectedEngine, .phaser)
            XCTAssertEqual(proposal.selectedRoot, web)
            let afterProposal = try await workspace.storedRecord(context: result.context)
            XCTAssertNil(afterProposal,
                         "a proposal alone must never persist a selection")

            do {
                _ = try await workspace.coordinator.confirmProposal(
                    proposal, context: result.context, userConfirmed: false)
                XCTFail("an unconfirmed proposal became a selection")
            } catch let error as GameProjectFlowError {
                XCTAssertEqual(error, .proposalNotConfirmed)
            }
            let afterRejectedConfirm = try await workspace.storedRecord(
                context: result.context)
            XCTAssertNil(afterRejectedConfirm)

            let confirmed = try await workspace.coordinator.confirmProposal(
                proposal, context: result.context, userConfirmed: true)
            XCTAssertEqual(confirmed.state, .confirmed)
            XCTAssertEqual(confirmed.selectionSource, .explicit)
            XCTAssertEqual(confirmed.selectedRoot, web)
            XCTAssertEqual(confirmed.selectedEngine, .phaser)
            XCTAssertEqual(confirmed.selectionVerification, .evidenceMatched)
            XCTAssertEqual(confirmed.runSelection?.engine, .phaser)
            XCTAssertTrue(confirmed.persisted)
            let stored = try await workspace.storedRecord(context: result.context)
            XCTAssertEqual(stored?.selectedRoot, web)
            XCTAssertEqual(stored?.selectedEngine, .phaser)
            XCTAssertEqual(stored?.verification, .evidenceMatched)
        }
    }

    func testManualProposalPersistsOnlyAfterUserConfirmation() async throws {
        try await withSelectionWorkspace { workspace in
            let result = try await workspace.importFiles(unknownFiles())
            let proposal = try await workspace.coordinator.proposeSelection(
                root: nil, engine: .godot,
                evidencePaths: [try GameRelativePath("README.txt")],
                rationale: "The file layout is not a recognized engine marker.",
                generatedBy: "fixture-assistant", context: result.context)
            XCTAssertTrue(proposal.isManualUnverified)
            let noRecord = try await workspace.storedRecord(context: result.context)
            XCTAssertNil(noRecord)

            do {
                _ = try await workspace.coordinator.confirmProposal(
                    proposal, context: result.context, userConfirmed: false)
                XCTFail("an unconfirmed manual proposal became a selection")
            } catch let error as GameProjectFlowError {
                XCTAssertEqual(error, .proposalNotConfirmed)
            }

            let confirmed = try await workspace.coordinator.confirmProposal(
                proposal, context: result.context, userConfirmed: true)
            XCTAssertEqual(confirmed.selectionVerification, .manualUnverified)
            XCTAssertEqual(confirmed.selectedEngine, .godot)
            XCTAssertNil(confirmed.runSelection)
            let stored = try await workspace.storedRecord(context: result.context)
            XCTAssertEqual(stored?.verification, .manualUnverified)
        }
    }

    func testProposalRejectsForeignEvidenceInvalidRootsAndEmptyProjects() async throws {
        try await withSelectionWorkspace { workspace in
            let ambiguous = try await workspace.importFiles(nestedFiles())
            let web = try GameRelativePath("Web")
            do {
                _ = try await workspace.coordinator.proposeSelection(
                    root: web, engine: .phaser,
                    evidencePaths: [try GameRelativePath("Legacy/Game.rvproj2")],
                    rationale: "foreign evidence", generatedBy: "fixture-assistant",
                    context: ambiguous.context)
                XCTFail("evidence from another root was accepted")
            } catch let error as GameProjectFlowError {
                guard case .proposalEvidenceInvalid(let path) = error else {
                    XCTFail("wrong error \(error)"); return
                }
                XCTAssertEqual(path.value, "Legacy/Game.rvproj2")
            }

            let missing = try GameRelativePath("Missing")
            do {
                _ = try await workspace.coordinator.proposeSelection(
                    root: missing, engine: .phaser, evidencePaths: [],
                    rationale: "missing root", generatedBy: "fixture-assistant",
                    context: ambiguous.context)
                XCTFail("a missing proposal root was accepted")
            } catch let error as GameProjectFlowError {
                XCTAssertEqual(error, .rootNotAvailable(missing))
            }

            do {
                _ = try await workspace.coordinator.proposeSelection(
                    root: web, engine: .phaser, evidencePaths: [],
                    rationale: "  \n ", generatedBy: "fixture-assistant",
                    context: ambiguous.context)
                XCTFail("an empty rationale was accepted")
            } catch let error as GameProjectFlowError {
                guard case .proposalInvalid = error else {
                    XCTFail("wrong error \(error)"); return
                }
            }

        }
        try await withSelectionWorkspace { workspace in
            let empty = try await workspace.createEmpty()
            do {
                _ = try await workspace.coordinator.proposeSelection(
                    root: nil, engine: .godot, evidencePaths: [],
                    rationale: "empty project", generatedBy: "fixture-assistant",
                    context: empty.1)
                XCTFail("an empty project proposal was accepted")
            } catch let error as GameProjectFlowError {
                XCTAssertEqual(error, .emptyProjectSelection)
            }
        }
    }

    func testProposalIsStaleAfterTheProjectRevisionChanges() async throws {
        try await withSelectionWorkspace { workspace in
            let result = try await workspace.importFiles(nestedFiles())
            let web = try GameRelativePath("Web")
            let proposal = try await workspace.coordinator.proposeSelection(
                root: web, engine: .phaser,
                evidencePaths: [try GameRelativePath("Web/package.json")],
                rationale: "Web contains Phaser.", generatedBy: "fixture-assistant",
                context: result.context)

            _ = try await workspace.repository.commit(
                workspace.projectID, owner: workspace.owner,
                expectedRevision: result.context.savedRevision,
                changes: [.write(try GameRelativePath("notes.txt"),
                                 Data("later edit".utf8))])
            let changed = try await workspace.context()
            do {
                _ = try await workspace.coordinator.confirmProposal(
                    proposal, context: changed, userConfirmed: true)
                XCTFail("a proposal from an older revision was confirmed")
            } catch let error as GameProjectFlowError {
                XCTAssertEqual(error, .proposalStale)
            }
            let staleRecord = try await workspace.storedRecord(context: changed)
            XCTAssertNil(staleRecord,
                         "a stale proposal must not persist anything")
        }
    }
}
