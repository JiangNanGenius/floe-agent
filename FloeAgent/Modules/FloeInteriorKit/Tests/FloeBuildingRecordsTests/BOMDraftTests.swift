import Foundation
import XCTest
@testable import FloeBuildingRecords

final class BOMDraftTests: XCTestCase {
    func testChineseEnglishAliasesPreviewAndRawRows() throws {
        let project = try TestProject()
        defer { project.cleanup() }

        let kitchen = try createRoom(project.store, name: "厨房", storey: "1F", kind: .kitchen, revision: 0)
        _ = try createRoom(project.store, name: "客厅", storey: "1F", kind: .livingRoom, revision: kitchen.receipt.revision)
        let csv = """
        Brand,型号,Qty,单位,房间,用途,产品名称,备注
        Example,SW-2G,2,台,厨房,设计需求,智能开关,note
        """
        let source = try importTextSource(
            project.store,
            kind: .table,
            title: "BOM",
            name: "bom.csv",
            mediaType: "text/csv",
            text: csv,
            revision: 2
        )

        let preview = try project.store.previewBOMDraft(
            csv: Data(csv.utf8),
            sourceVersionID: source.value.version.id
        )
        XCTAssertEqual(preview.projectID, project.store.projectID)
        XCTAssertEqual(preview.delimiter, .comma)
        XCTAssertEqual(preview.mapping.column(for: .brand), 0)
        XCTAssertEqual(preview.mapping.column(for: .model), 1)
        XCTAssertEqual(preview.mapping.column(for: .quantity), 2)
        XCTAssertEqual(preview.mapping.column(for: .unit), 3)
        XCTAssertEqual(preview.mapping.column(for: .room), 4)
        XCTAssertEqual(preview.mapping.column(for: .role), 5)
        XCTAssertEqual(preview.mapping.column(for: .productName), 6)
        XCTAssertEqual(preview.mapping.column(for: .notes), 7)
        XCTAssertEqual(preview.rows.count, 1)
        let row = preview.rows[0]
        XCTAssertEqual(row.brand, "Example")
        XCTAssertEqual(row.model, "SW-2G")
        XCTAssertEqual(row.quantity, 2)
        XCTAssertEqual(row.quantityKind, .devices)
        XCTAssertEqual(row.role, .designRequirement)
        XCTAssertEqual(row.matchedRoomID, kitchen.value.id)
        XCTAssertEqual(row.state, .ready)
        XCTAssertTrue(row.isCountedCandidate)
        XCTAssertEqual(row.rawFields.count, 8)
        XCTAssertEqual(row.rawFields[1], "SW-2G")
        XCTAssertFalse(row.rawRecord.isEmpty)
        XCTAssertEqual(row.locator, .spreadsheet(sheetName: nil, row: 2, cell: nil))
    }

    func testDraftPersistAndApplyIsIdempotent() throws {
        let project = try TestProject()
        defer { project.cleanup() }

        let kitchen = try createRoom(project.store, name: "厨房", revision: 0)
        let living = try createRoom(project.store, name: "客厅", revision: kitchen.receipt.revision)
        let csv = """
        Brand,Model,Quantity,Unit,Room,Role,Product
        Example,SW-2G,2,台,厨房,design,Switch
        Example,SW-2G,1,台,客厅,design,Switch
        """
        let source = try importTextSource(
            project.store,
            kind: .table,
            title: "BOM",
            name: "bom.csv",
            mediaType: "text/csv",
            text: csv,
            revision: living.receipt.revision
        )
        let target = try project.store.createBOMTarget(
            name: "Smart Home",
            expectedRevision: source.receipt.revision
        )
        let draft = try project.store.importBOMDraft(
            csv: Data(csv.utf8),
            sourceVersionID: source.value.version.id,
            targetID: target.value.id,
            expectedRevision: target.receipt.revision
        )
        XCTAssertTrue(draft.receipt.didChange)
        XCTAssertEqual(draft.value.rows.count, 2)
        XCTAssertTrue(draft.value.issues.isEmpty)
        XCTAssertEqual(draft.value.rows[0].allocationIdentity.isEmpty, false)

        let applied = try project.store.applyBOMDraft(
            draft.value.id,
            to: target.value.id,
            expectedRevision: draft.receipt.revision
        )
        XCTAssertTrue(applied.receipt.didChange)
        XCTAssertEqual(applied.value.adoptedItemIDs.count, 2)
        XCTAssertTrue(applied.value.skippedRowIDs.isEmpty)
        let items = try project.store.bomItems(targetID: target.value.id, limit: 100)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.compactMap(\.roomID)), Set([kitchen.value.id, living.value.id]))
        XCTAssertEqual(Set(items.map(\.quantity)), Set([1.0, 2.0]))
        for item in items {
            XCTAssertEqual(item.matchState, .sourceBackedCustom)
            XCTAssertEqual(item.capabilityState, .unknown)
            XCTAssertTrue(item.isCounted)
            XCTAssertNotNil(item.sourceLocator)
            if case .source(let versionID, let draftID, _) = item.origin {
                XCTAssertEqual(versionID, source.value.version.id)
                XCTAssertEqual(draftID, draft.value.id)
            } else {
                XCTFail("Expected source origin")
            }
        }

        let replay = try project.store.applyBOMDraft(
            draft.value.id,
            to: target.value.id,
            expectedRevision: draft.receipt.revision
        )
        XCTAssertFalse(replay.receipt.didChange)
        XCTAssertEqual(replay.receipt.revision, applied.receipt.revision)
        XCTAssertEqual(Set(replay.value.adoptedItemIDs), Set(applied.value.adoptedItemIDs))
        XCTAssertEqual(try project.store.bomItems(targetID: target.value.id, limit: 100).count, 2)
        XCTAssertEqual(try project.store.currentRevision(), applied.receipt.revision)
    }

    func testSelectedRowsAndDraftTargetBinding() throws {
        let project = try TestProject()
        defer { project.cleanup() }

        let kitchen = try createRoom(project.store, name: "厨房", revision: 0)
        let csv = """
        brand,model,quantity,unit,room,role
        Example,A,1,个,厨房,design
        Example,B,2,个,厨房,design
        """
        let source = try importTextSource(
            project.store,
            kind: .table,
            title: "BOM",
            name: "bom.csv",
            mediaType: "text/csv",
            text: csv,
            revision: kitchen.receipt.revision
        )
        let target = try project.store.createBOMTarget(
            name: "BOM",
            expectedRevision: source.receipt.revision
        )
        let otherTarget = try project.store.createBOMTarget(
            name: "Other BOM",
            expectedRevision: target.receipt.revision
        )
        let draft = try project.store.importBOMDraft(
            csv: Data(csv.utf8),
            sourceVersionID: source.value.version.id,
            targetID: target.value.id,
            expectedRevision: otherTarget.receipt.revision
        )
        XCTAssertEqual(draft.value.rows.count, 2)
        guard draft.value.rows.count == 2 else { return }

        assertRecordsError(
            try project.store.applyBOMDraft(
                draft.value.id,
                to: otherTarget.value.id,
                expectedRevision: draft.receipt.revision
            ),
            .draftTargetMismatch
        )
        assertRecordsError(
            try project.store.applyBOMDraft(
                draft.value.id,
                to: target.value.id,
                selectedRowIDs: [],
                expectedRevision: draft.receipt.revision
            ),
            .emptySelection
        )
        let unknownRowID = BOMDraftRowID()
        assertRecordsError(
            try project.store.applyBOMDraft(
                draft.value.id,
                to: target.value.id,
                selectedRowIDs: [unknownRowID],
                expectedRevision: draft.receipt.revision
            ),
            .unknownDraftRow(unknownRowID)
        )

        let first = try project.store.applyBOMDraft(
            draft.value.id,
            to: target.value.id,
            selectedRowIDs: [draft.value.rows[0].id],
            expectedRevision: draft.receipt.revision
        )
        XCTAssertEqual(first.value.adoptedItemIDs.count, 1)
        XCTAssertEqual(try project.store.bomItems(targetID: target.value.id).count, 1)
        let second = try project.store.applyBOMDraft(
            draft.value.id,
            to: target.value.id,
            selectedRowIDs: [draft.value.rows[1].id],
            expectedRevision: first.receipt.revision
        )
        XCTAssertEqual(second.value.adoptedItemIDs.count, 1)
        XCTAssertEqual(try project.store.bomItems(targetID: target.value.id).count, 2)
    }

    func testRolesAndQuantityKindsStaySeparate() throws {
        let project = try TestProject()
        defer { project.cleanup() }

        let kitchen = try createRoom(project.store, name: "厨房", revision: 0)
        _ = try createRoom(project.store, name: "客厅", revision: kitchen.receipt.revision)
        let csv = """
        brand,model,quantity,unit,room,role,product_name
        Example,D1,2,台,厨房,design,Switch
        Example,C1,8,路,厨房,ordered,Controller
        Example,M1,12.5,米,客厅,design,Cable
        Example,S1,1,套,客厅,design,SensorKit
        Example,P1,2,包,客厅,ordered,ConnectorPack
        """
        let source = try importTextSource(
            project.store,
            kind: .table,
            title: "BOM",
            name: "bom.csv",
            mediaType: "text/csv",
            text: csv,
            revision: 2
        )
        let target = try project.store.createBOMTarget(
            name: "BOM",
            expectedRevision: source.receipt.revision
        )
        let draft = try project.store.importBOMDraft(
            csv: Data(csv.utf8),
            sourceVersionID: source.value.version.id,
            targetID: target.value.id,
            expectedRevision: target.receipt.revision
        )
        XCTAssertTrue(draft.value.issues.isEmpty)
        let applied = try project.store.applyBOMDraft(
            draft.value.id,
            to: target.value.id,
            expectedRevision: draft.receipt.revision
        )
        XCTAssertEqual(applied.value.adoptedItemIDs.count, 5)

        let summary = try project.store.bomQuantitySummary(targetID: target.value.id)
        XCTAssertEqual(summary.countedItemCount, 5)
        XCTAssertEqual(summary.uncountedItemCount, 0)
        XCTAssertEqual(summary.deviceCount, 2)
        XCTAssertEqual(summary.channelCount, 8)
        XCTAssertEqual(summary.metreCount, 12.5)
        XCTAssertEqual(summary.setCount, 1)
        XCTAssertEqual(summary.packageCount, 2)
        XCTAssertEqual(summary.totalsByKind[.devices], 2)
        XCTAssertEqual(summary.totalsByKind[.channels], 8)
        XCTAssertEqual(summary.totalsByKind[.metres], 12.5)
        XCTAssertEqual(try project.store.bomItems(targetID: target.value.id, role: .ordered).count, 2)
        XCTAssertEqual(try project.store.bomItems(targetID: target.value.id, role: .designRequirement).count, 3)
    }

    func testMissingModelAndUnknownUnitRemainUncountedIssues() throws {
        let project = try TestProject()
        defer { project.cleanup() }

        let kitchen = try createRoom(project.store, name: "厨房", revision: 0)
        let csv = """
        brand,model,quantity,unit,room,product_name
        Example,,2,个,厨房,Ghost Switch
        Example,X1,3,furlong,厨房,Unknown Unit
        Example,X2,4,台,厨房,Good Switch
        """
        let source = try importTextSource(
            project.store,
            kind: .table,
            title: "BOM",
            name: "bom.csv",
            mediaType: "text/csv",
            text: csv,
            revision: kitchen.receipt.revision
        )
        let target = try project.store.createBOMTarget(
            name: "BOM",
            expectedRevision: source.receipt.revision
        )
        let draft = try project.store.importBOMDraft(
            csv: Data(csv.utf8),
            sourceVersionID: source.value.version.id,
            targetID: target.value.id,
            expectedRevision: target.receipt.revision
        )
        XCTAssertEqual(draft.value.rows[0].state, .needsReview)
        XCTAssertEqual(draft.value.rows[1].state, .needsReview)
        XCTAssertEqual(draft.value.rows[2].state, .ready)
        XCTAssertTrue(draft.value.issues.contains { $0.kind == .missingModel })
        XCTAssertTrue(draft.value.issues.contains { $0.kind == .unknownUnit })

        let applied = try project.store.applyBOMDraft(
            draft.value.id,
            to: target.value.id,
            expectedRevision: draft.receipt.revision
        )
        XCTAssertTrue(applied.value.pendingIssues.contains { $0.kind == .missingModel })
        XCTAssertTrue(applied.value.pendingIssues.contains { $0.kind == .unknownUnit })
        let items = try project.store.bomItems(targetID: target.value.id, limit: 100)
        XCTAssertEqual(items.count, 3)
        let missingModel = items.first { $0.rawModel == nil }
        let unknownUnit = items.first { $0.rawModel == "X1" }
        let good = items.first { $0.rawModel == "X2" }
        XCTAssertEqual(missingModel?.matchState, .identityUnresolved)
        XCTAssertEqual(missingModel?.isCounted, false)
        XCTAssertEqual(unknownUnit?.quantityKind, nil)
        XCTAssertEqual(unknownUnit?.isCounted, false)
        XCTAssertEqual(unknownUnit?.matchState, .sourceBackedCustom)
        XCTAssertEqual(good?.isCounted, true)
        XCTAssertEqual(good?.capabilityState, .unknown)

        let summary = try project.store.bomQuantitySummary(targetID: target.value.id)
        XCTAssertEqual(summary.countedItemCount, 1)
        XCTAssertEqual(summary.uncountedItemCount, 2)
        XCTAssertEqual(summary.deviceCount, 4)
    }

    func testNegativeAndZeroRowsDoNotCreateCounts() throws {
        let project = try TestProject()
        defer { project.cleanup() }

        let kitchen = try createRoom(project.store, name: "厨房", revision: 0)
        let csv = """
        brand,model,quantity,unit,room,role
        Example,NEG,-2,台,厨房,design
        Example,ZERO,0,台,厨房,design
        """
        let source = try importTextSource(
            project.store,
            kind: .table,
            title: "BOM",
            name: "bom.csv",
            mediaType: "text/csv",
            text: csv,
            revision: kitchen.receipt.revision
        )
        let target = try project.store.createBOMTarget(
            name: "BOM",
            expectedRevision: source.receipt.revision
        )
        let draft = try project.store.importBOMDraft(
            csv: Data(csv.utf8),
            sourceVersionID: source.value.version.id,
            targetID: target.value.id,
            expectedRevision: target.receipt.revision
        )
        XCTAssertEqual(draft.value.rows.map(\.state), [.blocked, .blocked])
        XCTAssertTrue(draft.value.issues.contains { $0.kind == .negativeQuantity })
        XCTAssertTrue(draft.value.issues.contains { $0.kind == .zeroQuantity })

        let applied = try project.store.applyBOMDraft(
            draft.value.id,
            to: target.value.id,
            expectedRevision: draft.receipt.revision
        )
        XCTAssertFalse(applied.receipt.didChange)
        XCTAssertEqual(applied.value.adoptedItemIDs.count, 0)
        XCTAssertEqual(applied.value.skippedRowIDs.count, 2)
        XCTAssertTrue(try project.store.bomItems(targetID: target.value.id).isEmpty)
        XCTAssertEqual(try project.store.bomQuantitySummary(targetID: target.value.id).countedItemCount, 0)
    }

    func testAmbiguousRoomIsNeverAssignedToFirstMatch() throws {
        let project = try TestProject()
        defer { project.cleanup() }

        let kitchen1F = try createRoom(project.store, name: "厨房", storey: "1F", revision: 0)
        let kitchen2F = try createRoom(project.store, name: "厨房", storey: "2F", revision: kitchen1F.receipt.revision)
        let csv = """
        brand,model,quantity,unit,room,storey,role
        Example,A1,1,个,厨房,,design
        Example,A2,1,个,厨房,2F,design
        """
        let source = try importTextSource(
            project.store,
            kind: .table,
            title: "BOM",
            name: "bom.csv",
            mediaType: "text/csv",
            text: csv,
            revision: kitchen2F.receipt.revision
        )
        let target = try project.store.createBOMTarget(
            name: "BOM",
            expectedRevision: source.receipt.revision
        )
        let draft = try project.store.importBOMDraft(
            csv: Data(csv.utf8),
            sourceVersionID: source.value.version.id,
            targetID: target.value.id,
            expectedRevision: target.receipt.revision
        )
        XCTAssertEqual(draft.value.rows[0].matchedRoomID, nil)
        XCTAssertEqual(draft.value.rows[0].state, .needsReview)
        XCTAssertEqual(draft.value.rows[1].matchedRoomID, kitchen2F.value.id)
        XCTAssertTrue(draft.value.issues.contains { $0.kind == .ambiguousRoom })

        _ = try project.store.applyBOMDraft(
            draft.value.id,
            to: target.value.id,
            expectedRevision: draft.receipt.revision
        )
        let items = try project.store.bomItems(targetID: target.value.id, limit: 100)
        XCTAssertEqual(items.count, 2)
        let unplaced = items.first { $0.rawModel == "A1" }
        let placed = items.first { $0.rawModel == "A2" }
        XCTAssertNil(unplaced?.roomID)
        XCTAssertEqual(placed?.roomID, kitchen2F.value.id)
        XCTAssertEqual(unplaced?.isCounted, true)
        XCTAssertEqual(placed?.isCounted, true)
    }

    func testNewSourceVersionComparisonAndManualPreservation() throws {
        let project = try TestProject()
        defer { project.cleanup() }

        let kitchen = try createRoom(project.store, name: "厨房", revision: 0)
        let v1 = """
        brand,model,quantity,unit,room,role
        Example,SW-2G,2,台,厨房,design
        Example,MW-1,1,个,厨房,design
        """
        let source = try importTextSource(
            project.store,
            kind: .table,
            title: "BOM",
            name: "bom-v1.csv",
            mediaType: "text/csv",
            text: v1,
            revision: kitchen.receipt.revision
        )
        let target = try project.store.createBOMTarget(
            name: "BOM",
            expectedRevision: source.receipt.revision
        )
        let draft1 = try project.store.importBOMDraft(
            csv: Data(v1.utf8),
            sourceVersionID: source.value.version.id,
            targetID: target.value.id,
            expectedRevision: target.receipt.revision
        )
        _ = try project.store.applyBOMDraft(
            draft1.value.id,
            to: target.value.id,
            expectedRevision: draft1.receipt.revision
        )
        let v1Items = try project.store.bomItems(targetID: target.value.id, limit: 100)
        XCTAssertEqual(v1Items.count, 2)
        let swID = v1Items.first { $0.rawModel == "SW-2G" }?.id

        let manual = try project.store.addManualBOMItem(
            ManualBOMItemDraft(
                targetID: target.value.id,
                role: .designRequirement,
                roomID: kitchen.value.id,
                model: "MANUAL-1",
                productName: "Manual item",
                quantity: 1,
                quantityKind: .devices
            ),
            expectedRevision: (try project.store.currentRevision())
        )
        XCTAssertTrue(manual.receipt.didChange)

        let v2 = """
        brand,model,quantity,unit,room,role
        Example,SW-2G,3,台,厨房,design
        Example,ADD-1,1,个,厨房,design
        """
        let version2 = try project.store.addSourceVersion(
            source.value.source.id,
            data: Data(v2.utf8),
            originalName: "bom-v2.csv",
            mediaType: "text/csv",
            expectedRevision: (try project.store.currentRevision())
        )
        let draft2 = try project.store.importBOMDraft(
            csv: Data(v2.utf8),
            sourceVersionID: version2.value.id,
            targetID: target.value.id,
            expectedRevision: version2.receipt.revision
        )
        let comparison = try project.store.compareBOMDrafts(
            previousDraftID: draft1.value.id,
            currentDraftID: draft2.value.id
        )
        XCTAssertEqual(comparison.added.count, 1)
        XCTAssertEqual(comparison.changed.count, 1)
        XCTAssertEqual(comparison.absent.count, 1)
        XCTAssertEqual(comparison.added.first?.model, "ADD-1")
        XCTAssertEqual(comparison.changed.first?.fields.contains(.quantity), true)
        XCTAssertEqual(comparison.absent.first?.model, "MW-1")

        _ = try project.store.applyBOMDraft(
            draft2.value.id,
            to: target.value.id,
            expectedRevision: draft2.receipt.revision
        )
        let finalItems = try project.store.bomItems(targetID: target.value.id, limit: 100)
        XCTAssertEqual(finalItems.count, 4)
        let sw = finalItems.first { $0.rawModel == "SW-2G" }
        XCTAssertEqual(sw?.id, swID)
        XCTAssertEqual(sw?.quantity, 3)
        if let sw, case .source(let versionID, _, _) = sw.origin {
            XCTAssertEqual(versionID, version2.value.id)
        } else {
            XCTFail("SW item should retain source origin")
        }
        XCTAssertNotNil(finalItems.first { $0.rawModel == "MW-1" })
        XCTAssertNotNil(finalItems.first { $0.rawModel == "MANUAL-1" })
    }

    func testDraftImportFingerprintReuse() throws {
        let project = try TestProject()
        defer { project.cleanup() }

        let kitchen = try createRoom(project.store, name: "厨房", revision: 0)
        let csv = """
        brand,model,quantity,unit,room,role
        Example,SW-2G,2,台,厨房,design
        """
        let source = try importTextSource(
            project.store,
            kind: .table,
            title: "BOM",
            name: "bom.csv",
            mediaType: "text/csv",
            text: csv,
            revision: kitchen.receipt.revision
        )
        let target = try project.store.createBOMTarget(
            name: "BOM",
            expectedRevision: source.receipt.revision
        )
        let first = try project.store.importBOMDraft(
            csv: Data(csv.utf8),
            sourceVersionID: source.value.version.id,
            targetID: target.value.id,
            expectedRevision: target.receipt.revision
        )
        let replay = try project.store.importBOMDraft(
            csv: Data(csv.utf8),
            sourceVersionID: source.value.version.id,
            targetID: target.value.id,
            expectedRevision: target.receipt.revision
        )
        XCTAssertFalse(replay.receipt.didChange)
        XCTAssertEqual(replay.value.id, first.value.id)
        XCTAssertEqual(replay.receipt.revision, first.receipt.revision)
        XCTAssertEqual(try project.store.bomDraftSummaries(targetID: target.value.id).count, 1)
    }

    func testSampleProjectBuildsUsableRecords() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeBuildingRecordsSample-\(UUID().uuidString)", isDirectory: true)
        let result = try BuildingRecordsSamples.makeSampleProject(at: root)
        defer {
            try? result.store.close()
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertEqual(result.summary.bomItemCount, 6)
        XCTAssertEqual(try result.store.rooms().count, 4)
        XCTAssertEqual(try result.store.bomItems(targetID: result.summary.bomTargetID, limit: 100).count, 6)
        XCTAssertEqual(try result.store.bomDraft(result.summary.bomDraftID).rows.count, 6)
        XCTAssertEqual(try result.store.sourceVersion(result.summary.sourceVersionID).version, 1)
    }
}
