import XCTest
import Foundation
import Darwin
@testable import FloeElectronicsCore

final class EDALibraryProjectTests: XCTestCase {
    private func fixture(version: String = "1.0.0", value: String = "Exact part") throws -> EDALibraryPackage {
        let symbol = EDASymbolDefinition(id: UUID(uuidString: "7AA36352-BA8A-4BFA-9663-FBE96A510412")!, name: "Exact symbol", referencePrefix: "U",
            pins: [.init(number: "1", name: "IN", position: .init(-2.54, 0)), .init(number: "2", name: "OUT", position: .init(2.54, 0))],
            graphics: [.rectangle(.init(-1.27, -1.27), .init(1.27, 1.27), width: 0.2)])
        let footprint = EDAFootprintDefinition(id: UUID(uuidString: "7AB36352-BA8A-4BFA-9663-FBE96A510412")!, name: "Exact pad names",
            pads: [.init(number: "A", position: .init(-1, 0), size: .init(1, 1), shape: .rectangle), .init(number: "B", position: .init(1, 0), size: .init(1, 1), shape: .rectangle)])
        let bytes = Data("Synthetic, self-authored source fixture".utf8)
        let part = EDALibraryPart(id: "synthetic-part", name: value, kind: .device, category: "synthetic", manufacturer: "Synthetic manufacturer",
            aliases: ["alias", "演示"], parameters: ["Voltage": "3.3V", "PartNumber": "QA-Exact"], symbol: symbol, footprint: footprint,
            pinMap: .init(pinToPads: ["1": ["A"], "2": ["B"]]), sources: [.init(path: "original.txt", data: bytes)])
        return .init(id: "org.floe.test.library", version: version, title: "Synthetic library", parts: [part],
            licenses: [.init(id: "CC0-1.0", attribution: "Floe qualification fixture", text: "Self-authored synthetic fixture dedicated to the public domain.")], sourcePayloads: ["original.txt": bytes])
    }
    private func directory() throws -> URL {
        let base = ProcessInfo.processInfo.environment["FLOE_EDA_LIBRARY_PROOF_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("FloeEDALibraryTests")
        let root = base.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    func testStrictNativePackageRejectsUnknownFieldsAndChangedOriginal() throws {
        let package = try fixture(), bytes = try EDALibraryDigest.encoded(package)
        XCTAssertEqual(try EDALibraryPackage.decode(bytes), package)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["runShell"] = "do not execute"
        XCTAssertThrowsError(try EDALibraryPackage.decode(JSONSerialization.data(withJSONObject: object)))
        var changed = package; changed.sourcePayloads["original.txt"] = Data("different".utf8)
        XCTAssertThrowsError(try changed.validate())
        changed = package; changed.sourcePayloads["../escape"] = Data()
        XCTAssertThrowsError(try changed.validate())
    }
    func testSearchUsesActualModelAliasManufacturerParametersPinCountAndPackage() throws {
        let parts = try fixture().parts
        for query in [EDALibraryQuery(text: "alias 3.3v"), .init(text: "演示"), .init(manufacturer: "Synthetic manufacturer", pinCount: 2, footprint: "pad names")] {
            XCTAssertEqual(try EDALibrarySearch.search(parts, query: query).parts, parts)
        }
        XCTAssertTrue(try EDALibrarySearch.search(parts, query: .init(pinCount: 3)).parts.isEmpty)
        XCTAssertThrowsError(try EDALibrarySearch.search(parts, query: .init(limit: 0)))
        XCTAssertThrowsError(try EDALibrarySearch.search(parts, query: .init(), cancelled: { true }))
    }
    func testPartialQueryJSONUsesDocumentedDefaultsAndRejectsWrongFieldTypes() throws {
        let query = try JSONDecoder().decode(EDALibraryQuery.self, from: Data(#"{"text":"2N7002"}"#.utf8))
        XCTAssertEqual(query.text, "2N7002"); XCTAssertEqual(query.offset, 0); XCTAssertEqual(query.limit, 50)
        XCTAssertThrowsError(try JSONDecoder().decode(EDALibraryQuery.self, from: Data(#"{"pinCount":true}"#.utf8)))
    }
    func testIdentifierSearchAcceptsConventionalPackageSpellingWithoutChangingParameterValues() throws {
        var part = try fixture().parts[0]; part.footprint!.name = "SOT-23"; part.name = "Example part"
        XCTAssertEqual(try EDALibrarySearch.search([part], query: .init(text: "SOT23")).parts.count, 1)
        XCTAssertEqual(try EDALibrarySearch.search([part], query: .init(text: "3.3V")).parts.count, 1)
        XCTAssertTrue(try EDALibrarySearch.search([part], query: .init(text: "33V")).parts.isEmpty)
    }
    func testExplicitNonidenticalPinPadMapAndShortCircuitConflictAreChecked() throws {
        let part = try fixture().parts[0]
        try part.pinMap!.validate(symbol: part.symbol!, footprint: part.footprint!)
        XCTAssertThrowsError(try EDALibraryPinMap.matchingNumbers(symbol: part.symbol!, footprint: part.footprint!))
        let mapped = try part.pinMap!.padNets(pinNets: ["1": "input", "2": "output"])
        XCTAssertEqual(mapped, ["A": "input", "B": "output"])
        let short = EDALibraryPinMap(pinToPads: ["1": ["A"], "2": ["A", "B"]])
        XCTAssertThrowsError(try short.padNets(pinNets: ["1": "input", "2": "output"]))
        XCTAssertThrowsError(try EDALibraryPinMap(pinToPads: ["1": ["A"]]).validate(symbol: part.symbol!, footprint: part.footprint!))
    }
    func testPlacementForwardAnnotationAndBOMKeepTheSameComponentAndPhysicalMap() throws {
        let snapshot = try EDALibrarySnapshot(package: fixture(), partID: "synthetic-part")
        var project = EDAProject(title: "Original")
        let placed = try EDALibraryProject.place(snapshot, into: &project, sheetID: project.sheets[0].id, position: .zero)
        let component = try XCTUnwrap(project.components.first)
        project.sheets[0].labels = [.init(name: "INPUT", position: .init(-2.54, 0)), .init(name: "OUTPUT", position: .init(2.54, 0))]
        let plan = try EDAForwardAnnotation.plan(project, boardID: project.boards[0].id)
        XCTAssertTrue(plan.canApply)
        let footprint = try XCTUnwrap(plan.updatedBoard.footprints.first)
        XCTAssertEqual(footprint.componentID, placed.componentID); XCTAssertEqual(footprint.reference, component.reference)
        XCTAssertEqual(Set(footprint.padNets.keys), ["A", "B"])
        XCTAssertNotEqual(footprint.padNets["A"], footprint.padNets["B"])
        let bom = try EDAExchange.export(project, format: .bom)
        let text = String(decoding: bom.files[0].data, as: UTF8.self)
        XCTAssertTrue(text.contains("Synthetic manufacturer")); XCTAssertTrue(text.contains("QA-Exact"))
        XCTAssertEqual(try EDALibraryProject.snapshot(placed.snapshotSHA256, in: project), snapshot)
    }
    func testSchematicAndBoardPlacementReuseSameComponentWithoutDuplicatingTheBOM() throws {
        let snapshot = try EDALibrarySnapshot(package: fixture(), partID: "synthetic-part")
        var project = EDAProject(title: "Original")
        let board = try EDALibraryProject.place(snapshot, into: &project, boardID: project.boards[0].id, position: .init(10, 10))
        let sheet = try EDALibraryProject.place(snapshot, into: &project, sheetID: project.sheets[0].id, position: .zero, existingComponentID: board.componentID)
        XCTAssertEqual(board.componentID, sheet.componentID); XCTAssertEqual(project.components.count, 1)
        let before = project
        XCTAssertThrowsError(try EDALibraryProject.place(snapshot, into: &project, boardID: project.boards[0].id, position: .init(20, 10), existingComponentID: board.componentID))
        XCTAssertEqual(project, before)
    }
    func testReplacementReviewsDiffsPreservesIdentityAndRejectsMovedPinsAtomically() throws {
        let old = try EDALibrarySnapshot(package: fixture(), partID: "synthetic-part")
        let next = try EDALibrarySnapshot(package: fixture(version: "2.0.0", value: "New exact part"), partID: "synthetic-part")
        var project = EDAProject(title: "Original")
        let receipt = try EDALibraryProject.place(old, into: &project, sheetID: project.sheets[0].id, position: .zero)
        let plan = try EDALibraryProject.planReplacement(next, componentID: receipt.componentID!, project: project)
        XCTAssertTrue(plan.canApply); XCTAssertTrue(plan.differences.contains { $0.code == "device_identity" })
        let before = project
        XCTAssertThrowsError(try EDALibraryProject.replace(plan, acceptedDifferences: [], in: &project)); XCTAssertEqual(project, before)
        try EDALibraryProject.replace(plan, acceptedDifferences: Set(plan.differences.map(\.code)), in: &project)
        XCTAssertEqual(project.components[0].id, receipt.componentID); XCTAssertEqual(project.components[0].reference, before.components[0].reference)
        XCTAssertEqual(project.sheets[0].symbols, before.sheets[0].symbols)
        XCTAssertNotEqual(project.components[0].fields[EDALibraryProject.snapshotField], receipt.snapshotSHA256)
        XCTAssertNotNil(project.preservedSource["library/snapshots/" + receipt.snapshotSHA256])
        var movedPackage = try fixture(version: "3.0.0"); movedPackage.parts[0].symbol!.pins[0].position.x -= 1
        let moved = try EDALibrarySnapshot(package: movedPackage, partID: "synthetic-part")
        let blocked = try EDALibraryProject.planReplacement(moved, componentID: receipt.componentID!, project: project)
        XCTAssertFalse(blocked.canApply)
        let saved = project
        XCTAssertThrowsError(try EDALibraryProject.replace(blocked, acceptedDifferences: Set(blocked.differences.map(\.code)), in: &project)); XCTAssertEqual(project, saved)
    }
    func testRealVersionStoreKeepsOldDesignSnapshotAndSavedProjectReopensUnchanged() async throws {
        let root = try directory(), libraries = try EDALibraryStore(root: root.appendingPathComponent("Libraries"))
        let one = try fixture(), two = try fixture(version: "2.0.0", value: "Updated source")
        _ = try await libraries.install(one)
        let snapshot = try EDALibrarySnapshot(package: one, partID: "synthetic-part")
        let original = EDAProject(title: "Old original"), store = try await EDAProjectStore.create(root: root.appendingPathComponent("Project"), project: original)
        let loaded = try await store.load(); var editing = try EDAEditingSession(project: original, savedDigest: loaded.digest)
        try editing.transaction(expectedRevision: 0) { value in _ = try EDALibraryProject.place(snapshot, into: &value, sheetID: value.sheets[0].id, position: .zero) }
        let saved = try await store.save(editing.project, expectedRevision: 0, expectedDigest: loaded.digest)
        _ = try await libraries.install(two)
        let reopened = try await store.load(), currentLibrary = try await libraries.package(id: one.id)
        XCTAssertEqual(reopened, saved); XCTAssertEqual(currentLibrary.version, "2.0.0")
        let component = reopened.project.components[0], hash = component.fields[EDALibraryProject.snapshotField]!
        XCTAssertEqual(try EDALibraryProject.snapshot(hash, in: reopened.project).packageVersion, "1.0.0")
        XCTAssertEqual(try EDAExchange.decodeProject(EDAExchange.export(reopened.project, format: .project).files[0].data), reopened.project)
    }
    func testTwoStoreConcurrentInstallsDoNotLoseTheOtherLibraryAndVersionBytesAreImmutable() async throws {
        let root = try directory(), a = try EDALibraryStore(root: root), b = try EDALibraryStore(root: root)
        let one = try fixture(); var other = one; other.id = "org.floe.test.second"
        let otherPackage = other
        let receipts = try await withThrowingTaskGroup(of: EDALibraryInstalledVersion.self) { group in
            group.addTask { try await a.install(one) }
            group.addTask { try await b.install(otherPackage) }
            var completed: [EDALibraryInstalledVersion] = []
            for try await record in group { completed.append(record) }
            return completed
        }
        XCTAssertEqual(Set(receipts.map(\.packageID)), [one.id, other.id])
        let index = try await a.inventory(); XCTAssertEqual(index.installed.count, 2)
        var clobber = one; clobber.title = "Different bytes under same version"
        do { _ = try await a.install(clobber); XCTFail("immutable version replaced") } catch {}
        let old = try await b.package(id: one.id, version: one.version); XCTAssertEqual(old, one)
        do { _ = try await a.install(other, expectedInventoryRevision: 0); XCTFail("stale catalog revision accepted") } catch {}
        let final = try await b.inventory(); XCTAssertEqual(final, index)
    }
    func testParallelFirstUseSerializesLockCreationAndKeepsBothLibraryVersions() async throws {
        let packages = try fixture()
        let stores = try (0..<12).map { _ -> (EDALibraryStore, EDALibraryStore) in
            let root = try directory(); return (try EDALibraryStore(root: root), try EDALibraryStore(root: root))
        }
        let receipts = try await withThrowingTaskGroup(of: EDALibraryInstalledVersion.self) { group in
            for (first, second) in stores {
                var alternate = packages; alternate.id = "org.floe.test.parallel"
                let copy = alternate
                group.addTask { try await first.install(packages) }
                group.addTask { try await second.install(copy) }
            }
            var values: [EDALibraryInstalledVersion] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(receipts.count, 24)
        for (first, _) in stores {
            let index = try await first.inventory()
            XCTAssertEqual(index.installed.count, 2); XCTAssertEqual(index.activeVersions.count, 2)
        }
    }
    func testWaitingForAnotherLockOwnerCanBeCancelledWithoutPublishing() async throws {
        let root = try directory(), store = try EDALibraryStore(root: root), package = try fixture()
        let lock = open(root.appendingPathComponent(".library.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        XCTAssertGreaterThanOrEqual(lock, 0); guard lock >= 0 else { return }
        defer { close(lock) }; XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        let pending = Task { try await store.install(package) }
        try await Task.sleep(for: .milliseconds(40)); pending.cancel()
        do { _ = try await pending.value; XCTFail("cancelled lock wait published") }
        catch { XCTAssertTrue(error is CancellationError || (error as? EDAError) == .cancelled) }
        XCTAssertEqual(flock(lock, LOCK_UN), 0)
        let inventory = try await store.inventory(); XCTAssertEqual(inventory.revision, 0); XCTAssertTrue(inventory.installed.isEmpty)
    }
    func testCancelledInstallDoesNotPublishAnInventoryOrAlterTheInstalledVersion() async throws {
        let root = try directory(), store = try EDALibraryStore(root: root)
        let one = try fixture()
        do { _ = try await store.install(one, cancelled: { true }); XCTFail("cancelled install published") }
        catch { XCTAssertEqual(error as? EDAError, .cancelled) }
        let empty = try await store.inventory(); XCTAssertEqual(empty.revision, 0); XCTAssertTrue(empty.installed.isEmpty)
        _ = try await store.install(one)
        let before = try await store.inventory(), bytes = try Data(contentsOf: root.appendingPathComponent("index.json"))
        do { _ = try await store.install(fixture(version: "2.0.0"), cancelled: { true }); XCTFail("cancelled update published") }
        catch { XCTAssertEqual(error as? EDAError, .cancelled) }
        let after = try await store.inventory(); XCTAssertEqual(after, before)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("index.json")), bytes)
    }
    func testCatalogReferencesDisambiguateIdenticalPartNamesAndReadExactOldVersions() async throws {
        let root = try directory(), store = try EDALibraryStore(root: root)
        let one = try fixture(); var other = one; other.id = "org.floe.test.alternative"
        _ = try await store.install(one); _ = try await store.install(other)
        let catalog = try await store.catalog(), page = try catalog.search(.init(text: "exact", limit: 1))
        XCTAssertEqual(page.total, 2); XCTAssertEqual(page.nextOffset, 1)
        let second = try catalog.search(.init(text: "exact", offset: 1, limit: 1))
        XCTAssertNotEqual(page.entries[0].reference, second.entries[0].reference)
        let reference = page.entries[0].reference
        let old = try await store.snapshot(reference); XCTAssertEqual(old.part.id, "synthetic-part")
        let changed = EDALibraryReference(packageID: reference.packageID, version: reference.version, packageSHA256: String(repeating: "0", count: 64), partID: reference.partID)
        do { _ = try await store.snapshot(changed); XCTFail("changed reference digest accepted") } catch {}
        var newer = reference.packageID == one.id ? one : other; newer.version = "2.0.0"; newer.title = "New version"
        _ = try await store.install(newer)
        let preserved = try await store.snapshot(reference); XCTAssertEqual(preserved, old)
        let current = try await store.catalog(); XCTAssertTrue(current.entries.contains { $0.reference.packageID == reference.packageID && $0.reference.version == "2.0.0" })
    }
    func testProjectSnapshotRetainsActualOriginalSourceBytesAndRejectsChangedEmbeddedSource() throws {
        let package = try fixture(), snapshot = try EDALibrarySnapshot(package: package, partID: "synthetic-part")
        XCTAssertEqual(snapshot.originalSources?["original.txt"], package.sourcePayloads["original.txt"])
        var project = EDAProject(title: "Source original")
        let placed = try EDALibraryProject.place(snapshot, into: &project, sheetID: project.sheets[0].id, position: .zero)
        let reopened = try EDAExchange.decodeProject(EDAExchange.export(project, format: .project).files[0].data)
        XCTAssertEqual(try EDALibraryProject.snapshot(placed.snapshotSHA256, in: reopened).originalSources, snapshot.originalSources)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: EDALibraryDigest.encoded(snapshot)) as? [String: Any])
        json["originalSources"] = ["original.txt": Data("changed".utf8).base64EncodedString()]
        let invalid = try JSONDecoder().decode(EDALibrarySnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try invalid.validate())
        let before = project; XCTAssertThrowsError(try EDALibraryProject.adopt(invalid, into: &project)); XCTAssertEqual(project, before)
    }
    func testExplicitIndependentSymbolFootprintAssociationKeepsSourcesAndDoesNotClaimAManufacturerPart() throws {
        var symbols = try fixture(), footprints = symbols
        symbols.id = "user.symbol"; symbols.parts[0].kind = .symbol; symbols.parts[0].footprint = nil; symbols.parts[0].pinMap = nil
        footprints.id = "user.footprint"; footprints.parts[0].kind = .footprint; footprints.parts[0].symbol = nil; footprints.parts[0].pinMap = nil
        let source = try EDALibrarySnapshot(package: symbols, partID: "synthetic-part"), physical = try EDALibrarySnapshot(package: footprints, partID: "synthetic-part")
        let map = EDALibraryPinMap(pinToPads: ["1": ["A"], "2": ["B"]])
        let package = try EDALibraryBinding.package(symbol: source, footprint: physical, pinMap: map, name: "My explicit combination")
        XCTAssertEqual(package.parts[0].kind, .generic); XCTAssertEqual(package.parts[0].parameters["PartNumber"], ""); XCTAssertTrue(package.parts[0].manufacturer.isEmpty)
        XCTAssertEqual(Set(package.sourcePayloads.keys), ["symbol/original.txt", "footprint/original.txt"])
        XCTAssertEqual(try EDALibraryPackage.decode(EDALibraryDigest.encoded(package)), package)
        XCTAssertThrowsError(try EDALibraryBinding.package(symbol: source, footprint: physical, pinMap: .init(pinToPads: ["1": ["A"]])))
        let snapshot = try EDALibrarySnapshot(package: package, partID: package.parts[0].id)
        var project = EDAProject(title: "Associated original")
        let placed = try EDALibraryProject.place(snapshot, into: &project, sheetID: project.sheets[0].id, position: .zero)
        XCTAssertEqual(try EDALibraryProject.snapshot(placed.snapshotSHA256, in: project).part.pinMap, map)
    }
    func testSourceBlockingCompatibilityCannotBeRemovedByUserAssociation() throws {
        var package = try fixture(); package.parts[0].notices = [.init("unsupported_shape", .blocking, path: "fixture", detail: "Synthetic unsupported source")]
        let blocked = try EDALibrarySnapshot(package: package, partID: "synthetic-part"), available = try EDALibrarySnapshot(package: fixture(), partID: "synthetic-part")
        XCTAssertThrowsError(try EDALibraryBinding.package(symbol: blocked, footprint: available, pinMap: .init(pinToPads: ["1": ["A"], "2": ["B"]])))
    }
    func testRepeatedSignedDeliveryPreservesExplicitUserVersionChoiceAndOldDesignSnapshot() async throws {
        let root = try directory(), store = try EDALibraryStore(root: root), one = try fixture(), two = try fixture(version: "2.0.0"), three = try fixture(version: "3.0.0")
        _ = try await store.install(one)
        let snapshot = try EDALibrarySnapshot(package: one, partID: "synthetic-part")
        var original = EDAProject(title: "Pinned old design")
        let placed = try EDALibraryProject.place(snapshot, into: &original, sheetID: original.sheets[0].id, position: .zero)
        let oldBytes = try EDALibraryDigest.encoded(original), delivered = EDALibraryDigest.sha256(Data("verified content2".utf8))
        _ = try await store.install(two, deliveredContentSHA256: delivered)
        _ = try await store.install(one) // Explicit native version-picker choice.
        let before = try await store.inventory()
        _ = try await store.install(two, deliveredContentSHA256: delivered)
        let after = try await store.inventory(); XCTAssertEqual(after, before); XCTAssertEqual(after.activeVersions[one.id], "1.0.0")
        _ = try await store.install(three, deliveredContentSHA256: EDALibraryDigest.sha256(Data("verified content3".utf8)))
        let next = try await store.inventory(); XCTAssertEqual(next.activeVersions[one.id], "3.0.0")
        XCTAssertEqual(try EDALibraryDigest.encoded(original), oldBytes)
        XCTAssertEqual(try EDALibraryProject.snapshot(placed.snapshotSHA256, in: original), snapshot)
    }
    func testInvalidOrCancelledContentDeliveryDoesNotAdvanceItsReceipt() async throws {
        let root = try directory(), store = try EDALibraryStore(root: root), one = try fixture()
        _ = try await store.install(one); let before = try await store.inventory()
        do { _ = try await store.install(fixture(version: "2.0.0"), deliveredContentSHA256: "invalid"); XCTFail("invalid receipt accepted") } catch {}
        do { _ = try await store.install(fixture(version: "2.0.0"), deliveredContentSHA256: String(repeating: "a", count: 64), cancelled: { true }); XCTFail("cancelled content published") } catch {}
        let after = try await store.inventory(); XCTAssertEqual(after, before)
    }
    func testProjectLocalGeometryEditsRemainIndependentWhenTheSameLibraryPartIsChosenAgain() throws {
        let snapshot = try EDALibrarySnapshot(package: fixture(), partID: "synthetic-part")
        var project = EDAProject(title: "Locally edited definitions")
        let first = try EDALibraryProject.place(snapshot, into: &project, sheetID: project.sheets[0].id, position: .zero)
        let symbolIndex = try XCTUnwrap(project.symbols.firstIndex { $0.id == first.symbolID }), footprintIndex = try XCTUnwrap(project.footprints.firstIndex { $0.id == first.footprintID })
        project.symbols[symbolIndex].graphics.append(.circle(center: .zero, radius: 1, width: 0.2))
        project.footprints[footprintIndex].pads[0].position.x -= 1
        let localSymbol = project.symbols[symbolIndex], localFootprint = project.footprints[footprintIndex]
        XCTAssertNil(try EDALibraryProject.boundSnapshot(symbolID: localSymbol.id, in: project))
        XCTAssertNil(try EDALibraryProject.boundSnapshot(footprintID: localFootprint.id, in: project))
        let second = try EDALibraryProject.place(snapshot, into: &project, sheetID: project.sheets[0].id, position: .init(10, 0))
        XCTAssertNotEqual(first.symbolID, second.symbolID); XCTAssertNotEqual(first.footprintID, second.footprintID)
        XCTAssertEqual(project.symbols[symbolIndex], localSymbol); XCTAssertEqual(project.footprints[footprintIndex], localFootprint)
        let third = try EDALibraryProject.place(snapshot, into: &project, sheetID: project.sheets[0].id, position: .init(20, 0))
        XCTAssertEqual(second.symbolID, third.symbolID); XCTAssertEqual(second.footprintID, third.footprintID)
        XCTAssertEqual(project.components.first { $0.id == first.componentID }?.symbolID, localSymbol.id)
    }
    func testIdenticalReplacementIsNotReportedAsADeviceChangeAndSourceChangesAreExplicit() throws {
        let source = try fixture(), snapshot = try EDALibrarySnapshot(package: source, partID: "synthetic-part")
        var project = EDAProject(title: "Replacement review")
        let receipt = try EDALibraryProject.place(snapshot, into: &project, sheetID: project.sheets[0].id, position: .zero)
        let same = try EDALibraryProject.planReplacement(snapshot, componentID: receipt.componentID!, project: project)
        XCTAssertTrue(same.differences.isEmpty)
        var version = source; version.version = "2.0.0"
        let next = try EDALibrarySnapshot(package: version, partID: "synthetic-part")
        let plan = try EDALibraryProject.planReplacement(next, componentID: receipt.componentID!, project: project)
        XCTAssertTrue(plan.differences.contains { $0.code == "library_source" }); XCTAssertFalse(plan.differences.contains { $0.code == "device_identity" })
    }
    func testDeclarativeContentGateBindsActualPackageIdentityAndRejectsScriptsOrChangedBytes() throws {
        var package = try fixture(); package.id = EDALibraryContent.packagePrefix + "synthetic"
        let bytes = try EDALibraryDigest.encoded(package)
        func files(_ data: Data, version: Any = 1) throws -> [String: Data] {
            let metadata: [String: Any] = ["schemaVersion": version, "id": package.id, "version": package.version, "kind": "templates", "template": "Library.json", "domain": "org.floe.electronics.library", "librarySHA256": EDALibraryDigest.sha256(bytes)]
            return ["content.json": try JSONSerialization.data(withJSONObject: metadata), "Library.json": data]
        }
        let valid = try files(bytes)
        XCTAssertEqual(try EDALibraryContent.decode(packageID: package.id, version: package.version, files: valid), package)
        XCTAssertThrowsError(try EDALibraryContent.decode(packageID: package.id, version: "2.0.0", files: valid))
        XCTAssertThrowsError(try EDALibraryContent.decode(packageID: package.id, version: package.version, files: files(Data("changed".utf8))))
        var scripted = valid; scripted["scripts/hook.sh"] = Data("do not execute".utf8)
        XCTAssertThrowsError(try EDALibraryContent.decode(packageID: package.id, version: package.version, files: scripted))
        XCTAssertThrowsError(try EDALibraryContent.decode(packageID: package.id, version: package.version, files: files(bytes, version: true)))
    }
    func testPinMapJSONCanOmitOnlyTheDocumentedEmptyExtraPadList() throws {
        let map = try JSONDecoder().decode(EDALibraryPinMap.self, from: Data(#"{"pinToPads":{"1":["A"],"2":["B"]}}"#.utf8))
        XCTAssertEqual(map.unconnectedPads, [])
        try map.validate(symbol: fixture().parts[0].symbol!, footprint: fixture().parts[0].footprint!)
        XCTAssertThrowsError(try JSONDecoder().decode(EDALibraryPinMap.self, from: Data(#"{"unconnectedPads":[]}"#.utf8)))
    }
    func testPreloadingANewBundledVersionDoesNotReplaceTheUsersActiveChoice() async throws {
        let root = try directory(), store = try EDALibraryStore(root: root), one = try fixture(), two = try fixture(version: "2.0.0")
        _ = try await store.install(one); _ = try await store.install(two, activate: false)
        let inventory = try await store.inventory()
        XCTAssertEqual(inventory.installed.count, 2); XCTAssertEqual(inventory.activeVersions[one.id], one.version)
        let available = try await store.package(id: one.id, version: two.version); XCTAssertEqual(available, two)
    }
    func testFavoritesAndRecentSurviveReopenAndCorruptIndexIsNeverReset() async throws {
        let root = try directory(), store = try EDALibraryStore(root: root)
        _ = try await store.install(fixture())
        try await store.setFavorite(packageID: "p", partID: "a", enabled: true)
        try await store.recordUse(packageID: "p", partID: "a"); try await store.recordUse(packageID: "p", partID: "b"); try await store.recordUse(packageID: "p", partID: "a")
        let reopened = try EDALibraryStore(root: root), inventory = try await reopened.inventory()
        XCTAssertEqual(inventory.preferences.favorites, ["p/a"]); XCTAssertEqual(inventory.preferences.recent, ["p/a", "p/b"])
        let broken = Data("{broken index".utf8); try broken.write(to: root.appendingPathComponent("index.json"), options: .atomic)
        do { _ = try await reopened.inventory(); XCTFail("corrupt index silently reset") } catch {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("index.json")), broken)
    }
}
