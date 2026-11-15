// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeBuildingWorkspace

final class BuildingEditorHistoryTests: XCTestCase {
    /// Reference-free, Sendable fixture so tests exercise real value and
    /// snapshot transitions instead of matching source text.
    private struct EditorValue: Equatable, Sendable {
        var width: Int
        var title: String
        var tags: [String]
    }

    private func value(_ width: Int, title: String = "Synthetic room") -> EditorValue {
        EditorValue(width: width, title: title, tags: ["fixture", "editor"])
    }

    func testInitialSeedIsLogicalBaselineWithoutPersistedVersion() throws {
        var history = BuildingEditorHistory(value: value(0), historyLimit: 8)
        XCTAssertEqual(history.value, value(0))
        XCTAssertFalse(history.isDirty)
        XCTAssertFalse(history.hasPersistedVersion)
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertFalse(history.isSaving)
        XCTAssertEqual(history.generation, 0)

        let capture = try XCTUnwrap(history.beginSave())
        XCTAssertTrue(history.isSaving)
        XCTAssertNil(history.beginSave())
        XCTAssertTrue(history.acknowledgeSave(capture))
        XCTAssertFalse(history.isSaving)
        XCTAssertTrue(history.hasPersistedVersion)
        XCTAssertFalse(history.isDirty)
        XCTAssertEqual(history.generation, 0)
    }

    func testPersistedSeedStartsCleanAndKeepsPersistedStatus() {
        let history = BuildingEditorHistory(value: value(1200), isPersisted: true, historyLimit: 8)
        XCTAssertTrue(history.hasPersistedVersion)
        XCTAssertFalse(history.isDirty)
        XCTAssertEqual(history.value, value(1200))
    }

    func testEditUndoRedoTransitions() {
        var history = BuildingEditorHistory(value: value(0), historyLimit: 10)
        let first = value(1)
        let second = value(2)

        XCTAssertTrue(history.edit(first))
        XCTAssertEqual(history.value, first)
        XCTAssertTrue(history.isDirty)
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.generation, 1)

        XCTAssertTrue(history.edit(second))
        XCTAssertEqual(history.generation, 2)

        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.value, first)
        XCTAssertTrue(history.isDirty)
        XCTAssertTrue(history.canRedo)
        XCTAssertEqual(history.generation, 3)

        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.value, value(0))
        XCTAssertFalse(history.isDirty)
        XCTAssertFalse(history.canUndo)
        XCTAssertTrue(history.canRedo)
        XCTAssertEqual(history.generation, 4)

        XCTAssertFalse(history.undo())
        XCTAssertEqual(history.generation, 4)

        XCTAssertTrue(history.redo())
        XCTAssertEqual(history.value, first)
        XCTAssertTrue(history.isDirty)

        XCTAssertTrue(history.redo())
        XCTAssertEqual(history.value, second)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.generation, 6)

        XCTAssertFalse(history.redo())
        XCTAssertEqual(history.generation, 6)
    }

    func testDivergentEditInvalidatesRedo() {
        var history = BuildingEditorHistory(value: value(0), historyLimit: 10)
        XCTAssertTrue(history.edit(value(1)))
        XCTAssertTrue(history.edit(value(2)))
        XCTAssertTrue(history.undo())
        XCTAssertTrue(history.canRedo)
        XCTAssertEqual(history.value, value(1))

        XCTAssertTrue(history.edit(value(3)))
        XCTAssertFalse(history.canRedo)
        XCTAssertFalse(history.redo())
        XCTAssertEqual(history.value, value(3))
    }

    func testBoundedHistoryEvictsOldestSnapshots() {
        var history = BuildingEditorHistory(value: value(0), historyLimit: 2)
        XCTAssertTrue(history.edit(value(1)))
        XCTAssertTrue(history.edit(value(2)))
        XCTAssertTrue(history.edit(value(3)))
        XCTAssertTrue(history.edit(value(4)))

        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.value, value(3))
        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.value, value(2))
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.undo())

        XCTAssertTrue(history.redo())
        XCTAssertEqual(history.value, value(3))
        XCTAssertTrue(history.redo())
        XCTAssertEqual(history.value, value(4))
        XCTAssertFalse(history.redo())
    }

    func testHistoryLimitClampsToMaximumOfTwoHundred() {
        var history = BuildingEditorHistory(value: value(0), historyLimit: 500)
        for width in 1...250 {
            XCTAssertTrue(history.edit(value(width)))
        }

        var undoCount = 0
        while history.undo() {
            undoCount += 1
        }
        XCTAssertEqual(undoCount, 200)
        XCTAssertEqual(history.value, value(50))
    }

    func testNoOpEditPreservesGenerationRedoAndHistory() {
        var history = BuildingEditorHistory(value: value(0), historyLimit: 10)
        XCTAssertFalse(history.edit(value(0)))
        XCTAssertEqual(history.generation, 0)
        XCTAssertFalse(history.canUndo)

        XCTAssertTrue(history.edit(value(1)))
        XCTAssertFalse(history.edit(value(1)))
        XCTAssertEqual(history.generation, 1)
        XCTAssertTrue(history.canUndo)

        XCTAssertTrue(history.undo())
        XCTAssertTrue(history.canRedo)
        XCTAssertFalse(history.edit(value(0)))
        XCTAssertTrue(history.canRedo)
        XCTAssertEqual(history.generation, 2)

        XCTAssertTrue(history.redo())
        XCTAssertEqual(history.value, value(1))
    }

    func testSaveCaptureSnapshotsExactValueAndGeneration() throws {
        var history = BuildingEditorHistory(value: value(0), historyLimit: 10)
        XCTAssertTrue(history.edit(value(1)))
        XCTAssertTrue(history.edit(value(2)))

        let capture = try XCTUnwrap(history.beginSave())
        XCTAssertEqual(capture.value, value(2))
        XCTAssertEqual(capture.generation, 2)
        XCTAssertTrue(history.isSaving)

        XCTAssertTrue(history.edit(value(3)))
        XCTAssertEqual(capture.value, value(2))
        XCTAssertEqual(capture.generation, 2)
        XCTAssertEqual(history.value, value(3))
        XCTAssertTrue(history.acknowledgeSave(capture))
        XCTAssertTrue(history.isDirty)
        XCTAssertEqual(history.generation, 3)
    }

    func testEditsDuringSaveRemainDirtyAfterAcknowledgement() throws {
        var history = BuildingEditorHistory(value: value(0), historyLimit: 10)
        XCTAssertTrue(history.edit(value(1)))
        let capture = try XCTUnwrap(history.beginSave())
        XCTAssertTrue(history.edit(value(2)))

        XCTAssertTrue(history.acknowledgeSave(capture))
        XCTAssertFalse(history.isSaving)
        XCTAssertTrue(history.hasPersistedVersion)
        XCTAssertTrue(history.isDirty)
        XCTAssertEqual(history.value, value(2))
        XCTAssertFalse(history.acknowledgeSave(capture))

        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.value, value(1))
        XCTAssertFalse(history.isDirty)
        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.value, value(0))
        XCTAssertTrue(history.isDirty)
    }

    func testFailedSaveKeepsCurrentEditsAndHistory() throws {
        var history = BuildingEditorHistory(value: value(0), historyLimit: 10)
        XCTAssertTrue(history.edit(value(1)))
        let capture = try XCTUnwrap(history.beginSave())
        XCTAssertTrue(history.edit(value(2)))

        XCTAssertTrue(history.failSave(capture))
        XCTAssertFalse(history.isSaving)
        XCTAssertFalse(history.hasPersistedVersion)
        XCTAssertTrue(history.isDirty)
        XCTAssertEqual(history.value, value(2))
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.failSave(capture))

        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.value, value(1))
        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.value, value(0))
        XCTAssertFalse(history.isDirty)
    }

    func testConcurrentBeginSaveIsRefused() throws {
        var history = BuildingEditorHistory(value: value(0), historyLimit: 10)
        let first = try XCTUnwrap(history.beginSave())
        XCTAssertNil(history.beginSave())
        XCTAssertTrue(history.isSaving)

        XCTAssertTrue(history.failSave(first))
        XCTAssertFalse(history.isSaving)
        let second = try XCTUnwrap(history.beginSave())
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(history.acknowledgeSave(second))
    }

    func testForeignCaptureIsIgnored() throws {
        var first = BuildingEditorHistory(value: value(0), historyLimit: 10)
        var second = BuildingEditorHistory(value: value(90), historyLimit: 10)
        let firstCapture = try XCTUnwrap(first.beginSave())
        let secondCapture = try XCTUnwrap(second.beginSave())

        XCTAssertFalse(first.acknowledgeSave(secondCapture))
        XCTAssertFalse(first.failSave(secondCapture))
        XCTAssertTrue(first.isSaving)
        XCTAssertTrue(second.isSaving)

        XCTAssertTrue(first.acknowledgeSave(firstCapture))
        XCTAssertTrue(second.failSave(secondCapture))
    }

    func testOldAcknowledgementIgnoredAfterReplaceFromStorage() throws {
        var history = BuildingEditorHistory(value: value(0), historyLimit: 10)
        XCTAssertTrue(history.edit(value(1)))
        let capture = try XCTUnwrap(history.beginSave())

        history.replaceFromStorage(value(2))
        XCTAssertFalse(history.acknowledgeSave(capture))
        XCTAssertFalse(history.failSave(capture))
        XCTAssertEqual(history.value, value(2))
        XCTAssertFalse(history.isDirty)
        XCTAssertTrue(history.hasPersistedVersion)
        XCTAssertFalse(history.isSaving)
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.generation, 2)
    }

    func testOldAcknowledgementIgnoredAfterDiscardChanges() throws {
        var history = BuildingEditorHistory(value: value(0), historyLimit: 10)
        XCTAssertTrue(history.edit(value(1)))
        let capture = try XCTUnwrap(history.beginSave())

        XCTAssertTrue(history.discardChanges())
        XCTAssertFalse(history.acknowledgeSave(capture))
        XCTAssertEqual(history.value, value(0))
        XCTAssertFalse(history.isDirty)
        XCTAssertFalse(history.hasPersistedVersion)
        XCTAssertFalse(history.isSaving)
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.generation, 2)
    }

    func testOldCaptureIgnoredAfterCompletionAndNewCapture() throws {
        var history = BuildingEditorHistory(value: value(0), historyLimit: 10)
        XCTAssertTrue(history.edit(value(1)))
        let first = try XCTUnwrap(history.beginSave())
        XCTAssertTrue(history.acknowledgeSave(first))

        let second = try XCTUnwrap(history.beginSave())
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(history.acknowledgeSave(first))
        XCTAssertTrue(history.isSaving)
        XCTAssertTrue(history.acknowledgeSave(second))
    }

    func testSuccessfulSaveRetainsUndoHistory() throws {
        var history = BuildingEditorHistory(value: value(0), historyLimit: 10)
        XCTAssertTrue(history.edit(value(1)))
        let capture = try XCTUnwrap(history.beginSave())
        XCTAssertTrue(history.acknowledgeSave(capture))

        XCTAssertTrue(history.canUndo)
        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.value, value(0))
        XCTAssertTrue(history.isDirty)
        XCTAssertTrue(history.redo())
        XCTAssertEqual(history.value, value(1))
        XCTAssertFalse(history.isDirty)
    }

    func testReplaceFromStorageResetsHistoryAndSaving() throws {
        var history = BuildingEditorHistory(value: value(0), historyLimit: 10)
        XCTAssertTrue(history.edit(value(1)))
        XCTAssertTrue(history.edit(value(2)))
        XCTAssertTrue(history.undo())
        XCTAssertTrue(history.canRedo)
        let capture = try XCTUnwrap(history.beginSave())

        history.replaceFromStorage(value(3), isPersisted: false)
        XCTAssertEqual(history.value, value(3))
        XCTAssertFalse(history.isDirty)
        XCTAssertFalse(history.hasPersistedVersion)
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertFalse(history.isSaving)
        XCTAssertEqual(history.generation, 4)
        XCTAssertFalse(history.acknowledgeSave(capture))
    }

    func testDiscardChangesRestoresBaselineAndClearsLifecycle() {
        var history = BuildingEditorHistory(value: value(0), isPersisted: true, historyLimit: 10)
        XCTAssertFalse(history.discardChanges())
        XCTAssertEqual(history.generation, 0)

        XCTAssertTrue(history.edit(value(1)))
        XCTAssertTrue(history.edit(value(2)))
        XCTAssertTrue(history.undo())
        XCTAssertTrue(history.isDirty)
        XCTAssertTrue(history.canRedo)
        XCTAssertEqual(history.generation, 3)

        XCTAssertTrue(history.discardChanges())
        XCTAssertEqual(history.value, value(0))
        XCTAssertFalse(history.isDirty)
        XCTAssertTrue(history.hasPersistedVersion)
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.generation, 4)

        XCTAssertTrue(history.edit(value(4)))
        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.value, value(0))
        XCTAssertFalse(history.isDirty)
        XCTAssertTrue(history.canRedo)
        XCTAssertTrue(history.discardChanges())
        XCTAssertFalse(history.canRedo)
    }

    func testZeroHistoryBudgetDisablesUndoAndRedoButNotSaving() throws {
        var history = BuildingEditorHistory(value: value(0), historyLimit: 0)
        XCTAssertTrue(history.edit(value(1)))
        XCTAssertTrue(history.isDirty)
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertFalse(history.undo())
        XCTAssertFalse(history.redo())
        XCTAssertEqual(history.value, value(1))
        XCTAssertEqual(history.generation, 1)

        XCTAssertTrue(history.edit(value(2)))
        XCTAssertFalse(history.undo())
        XCTAssertFalse(history.canUndo)

        let capture = try XCTUnwrap(history.beginSave())
        XCTAssertTrue(history.acknowledgeSave(capture))
        XCTAssertTrue(history.hasPersistedVersion)
        XCTAssertFalse(history.isDirty)
    }

    func testNegativeHistoryBudgetBehavesLikeZero() {
        var history = BuildingEditorHistory(value: value(0), historyLimit: -5)
        XCTAssertTrue(history.edit(value(1)))
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.undo())
        XCTAssertEqual(history.value, value(1))
    }

    func testIndependentHistoriesAndValueCopiesDoNotShareState() throws {
        var first = BuildingEditorHistory(value: value(0), historyLimit: 10)
        var second = BuildingEditorHistory(value: value(100), historyLimit: 10)

        XCTAssertTrue(first.edit(value(1)))
        XCTAssertTrue(second.edit(value(101)))
        XCTAssertTrue(first.undo())
        XCTAssertEqual(first.value, value(0))
        XCTAssertEqual(second.value, value(101))
        XCTAssertTrue(second.canUndo)

        let firstCapture = try XCTUnwrap(first.beginSave())
        let secondCapture = try XCTUnwrap(second.beginSave())
        XCTAssertTrue(first.acknowledgeSave(firstCapture))
        XCTAssertTrue(second.isSaving)
        XCTAssertTrue(second.failSave(secondCapture))
        XCTAssertFalse(second.hasPersistedVersion)

        var copy = first
        XCTAssertTrue(copy.edit(value(9)))
        XCTAssertEqual(first.value, value(0))
        XCTAssertEqual(copy.value, value(9))
        XCTAssertFalse(first.isDirty)
        XCTAssertTrue(copy.isDirty)
    }
}
