// SPDX-License-Identifier: MPL-2.0
// Deferred to Main's authorized App/native window. These call real stores and
// preview/import APIs; generating this source is not a test-pass claim.
#if canImport(UIKit)
import Foundation
import Testing
import FloeGISKit
import FloeHeavyEditorSupport
@testable import FloeApp

@Suite("GIS production original contracts", .serialized)
@MainActor struct GISProductionOriginalTests {
    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GISOriginalContract-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
    private func tree(_ root: URL) throws -> [String: String] {
        let values = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        var result: [String: String] = [:]
        while let file = values?.nextObject() as? URL {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(file.path.dropFirst(root.path.count + 1))] = previewHash(try Data(contentsOf: file))
            }
        }
        return result
    }
    private func fixture(_ root: URL) async throws -> (PersonalContentService, PersonalContentLibrary, PersonalContentRecord, URL) {
        let service = PersonalContentService(root: root)
        let record = try await service.create(kind: .geography, title: "Actual geography")
        let library = try await service.library(), location = try await library.resolve(record.id)
        return (service, library, record, location.url)
    }
    @Test func emptyMapPreviewReadsActualOriginalWithoutCreatingAnEditorOrLock() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (content, _, record, directory) = try await fixture(root)
        let lock = directory.appendingPathComponent("GIS/.document.lock")
        try FileManager.default.removeItem(at: lock)
        let before = try tree(directory)
        let previews = PersonalContentPreviewService()
        let request = try await previews.request(for: record, contentService: content, maximumPixelSize: 160)
        let preview = try await previews.preview(request)
        guard case .text(let text) = preview.content else { Issue.record("Empty saved GIS must expose its actual layer summary"); return }
        #expect(text.contains("EPSG:4326"))
        #expect(preview.provenance == .moduleSnapshot)
        #expect(try tree(directory) == before)
        #expect(!FileManager.default.fileExists(atPath: lock.path))
    }
    @Test func actualStoreCASRejectsAStaleWriterAndInvalidatesTheSavedReadPin() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, _, record, directory) = try await fixture(root)
        let before = try GISProjectOriginal.read(id: record.id, directory: directory)
        let one = try HeavyEditorProjectStore(directory: GISProjectOriginal.root(in: directory), documentID: record.id, kind: .gis)
        let two = try HeavyEditorProjectStore(directory: GISProjectOriginal.root(in: directory), documentID: record.id, kind: .gis)
        var state = before.state.object; state["title"] = .string("Committed map")
        let saved = try await one.commit(content: .object(state), title: "Committed map", expectedRevision: 0)
        #expect(saved.revision == 1)
        let durable = try GISProjectOriginal.read(id: record.id, directory: directory)
        do { _ = try await two.commit(content: before.document.content, expectedRevision: 0); Issue.record("Stale map commit replaced the original") }
        catch HeavyEditorError.revisionConflict { }
        catch { throw error }
        #expect(try GISProjectOriginal.read(id: record.id, directory: directory).sha256 == durable.sha256)
        do { try before.validate(); Issue.record("Old atomic-file identity pin remained valid") } catch { }
    }
    @Test func duplicateHasANewOriginalIdentityAndPreservesTheSourceAndProjectEnvelope() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, library, record, directory) = try await fixture(root)
        let saved = try GISProjectOriginal.read(id: record.id, directory: directory)
        let duplicate = try await library.create(kind: .geography, title: "Independent map copy") { target, id in
            try await GISProjectOriginal.copy(saved, to: target, id: id, title: "Independent map copy")
        }
        let copiedLocation = try await library.resolve(duplicate.id)
        let copied = try GISProjectOriginal.read(id: duplicate.id, directory: copiedLocation.url)
        #expect(copied.document.id != saved.document.id)
        #expect(copied.document.kind == .gis && copied.document.revision == 0)
        #expect(copied.state["title"].string == "Independent map copy")
        #expect(try GISProjectOriginal.read(id: record.id, directory: directory).sha256 == saved.sha256)
        let envelope = try EditorJSON.decode(GISProjectOriginal.projectData(saved))
        #expect(envelope["kind"].string == "gis" && envelope["data"] == saved.state)
        #expect(envelope["history"]["past"].array.isEmpty)
    }
    @Test func actualLibraryMovePreservesProjectIdentityAndRejectsAnOldLocationPin() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, library, record, directory) = try await fixture(root)
        let saved = try GISProjectOriginal.read(id: record.id, directory: directory)
        try await library.createFolder("Maps", in: [])
        let moved = try await library.move(record.id, to: ["Maps"], expectedRelativePath: record.relativePath)
        let current = try await library.resolve(record.id)
        #expect(moved.id == record.id && current.url != directory)
        #expect(try GISProjectOriginal.read(id: record.id, directory: current.url).sha256 == saved.sha256)
        do { try saved.validate(); Issue.record("Moved original accepted a stale path pin") } catch { }
    }
    @Test func nativeImportRunsTheActualGISDispatcherBeforePublishingItsLibraryRecord() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("actual-points.geojson")
        let bytes = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","id":"observed-site","geometry":{"type":"Point","coordinates":[151.2,-33.8]},"properties":{"name":"Actual site","value":17}}]}"#.utf8)
        try bytes.write(to: source)
        let service = PersonalContentService(root: root.appendingPathComponent("Library", isDirectory: true))
        let record = try await service.importGeography(source, folders: [])
        let location = try await service.library().resolve(record.id)
        let saved = try GISProjectOriginal.read(id: record.id, directory: location.url)
        let feature = try #require(saved.state["layers"].array.first?["data"]["features"].array.first)
        #expect(record.kind == .geography && saved.document.revision == 1)
        #expect(feature["properties"]["value"].number == 17)
        #expect(feature["geometry"]["coordinates"].array.first?.number == 151.2)
        #expect(try Data(contentsOf: source) == bytes)
    }
    /// Session's production resolver intentionally uses the actual Personal
    /// Library. These two fixtures therefore create unique test-owned originals
    /// there, close their service first, then remove only their own packages.
    private func sessionFixture() async throws -> (PersonalContentRecord, URL) {
        let record = try await PersonalContentService.shared.create(kind: .geography, title: "GIS session contract " + UUID().uuidString)
        let location = try await PersonalContentService.shared.library().resolve(record.id)
        return (record, location.url)
    }
    @Test func actualExternalCommitCanRefreshThenEditAndCloseWithoutAnOldPinConflict() async throws {
        let (record, directory) = try await sessionFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try await GISProjectSession.open(id: record.id, directory: directory)
        try session.beginPresentation()
        do {
            let use = try session.retainModelUse()
            do { try await session.refresh(); Issue.record("Refresh interrupted a live model use") }
            catch PersonalFileActionError.busy { }
            catch { session.releaseModelUse(use); throw error }
            #expect(!session.isClosed)
            session.releaseModelUse(use)
            let before = try GISProjectOriginal.read(id: record.id, directory: directory)
            let external = try HeavyEditorProjectStore(directory: GISProjectOriginal.root(in: directory), documentID: record.id, kind: .gis)
            var next = before.state.object; next["title"] = .string("Externally committed map")
            let committed = try await external.commit(content: .object(next), title: "Externally committed map", expectedRevision: before.document.revision)
            try await session.refresh()
            #expect(session.controller.document == committed)
            #expect(try session.originalSHA256() == GISProjectOriginal.read(id: record.id, directory: directory).sha256)
            _ = try await session.controller.execute("layer.create", arguments: .object(["name": .string("After refresh")]), expectedRevision: committed.revision)
            #expect(session.controller.document.revision == committed.revision + 1)
            let closed = await session.flushForClose()
            #expect(closed && session.isClosed)
        } catch { await session.presentationEnded(); throw error }
        await session.presentationEnded()
    }
    @Test func unchangedCloseKeepsRevisionAndACameraOnlyChangeStillPersists() async throws {
        let (record, directory) = try await sessionFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        // An untouched close must not append a bare document.save revision.
        let first = try await GISProjectSession.open(id: record.id, directory: directory)
        try first.beginPresentation()
        #expect(try GISProjectOriginal.read(id: record.id, directory: directory).document.revision == 0)
        #expect(await first.flushForClose())
        #expect(try GISProjectOriginal.read(id: record.id, directory: directory).document.revision == 0)

        // A real content edit already committed once; closing again is a no-op.
        let second = try await GISProjectSession.open(id: record.id, directory: directory)
        try second.beginPresentation()
        _ = try await second.controller.execute("layer.create", arguments: .object(["name": .string("No extra save")]), expectedRevision: 0)
        #expect(second.controller.document.revision == 1)
        #expect(await second.flushForClose())
        #expect(try GISProjectOriginal.read(id: record.id, directory: directory).document.revision == 1)

        // A real camera move is still a view change worth committing.
        let third = try await GISProjectSession.open(id: record.id, directory: directory)
        try third.beginPresentation()
        _ = try await third.controller.webView.evaluateJavaScript("window.FloeEditor.liveView={center:[-7.3334,20],zoom:3}; 'ok'")
        try await third.controller.refreshPresentation()
        #expect(await third.flushForClose())
        let saved = try GISProjectOriginal.read(id: record.id, directory: directory)
        #expect(saved.document.revision == 2)
        let view = saved.state["view"]
        #expect(abs((view["center"].array.first?.number ?? 0) - (-7.3334)) < 1e-9)
        #expect(view["zoom"].number == 3)
        // The existing CAS still rejects an old writer.
        let stale = try HeavyEditorProjectStore(directory: GISProjectOriginal.root(in: directory), documentID: record.id, kind: .gis)
        do { _ = try await stale.commit(content: saved.document.content, expectedRevision: 1); Issue.record("Stale view commit replaced the original") }
        catch HeavyEditorError.revisionConflict { }
        catch { throw error }
    }
    @Test func secondPresentationIsRefusedWithoutClosingTheFirstController() async throws {
        let (record, directory) = try await sessionFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try await GISProjectSession.open(id: record.id, directory: directory)
        try session.beginPresentation()
        do {
            do { try session.beginPresentation(); Issue.record("One WK controller was accepted by two presentations") }
            catch PersonalFileActionError.busy { }
            #expect(!session.isClosed)
            let revision = session.controller.document.revision
            _ = try await session.controller.execute("layer.create", arguments: .object(["name": .string("First window remains active")]), expectedRevision: revision)
            let closed = await session.flushForClose()
            #expect(closed && session.isClosed)
            let reopened = try await GISProjectSession.open(id: record.id, directory: directory)
            try reopened.beginPresentation()
            #expect(reopened !== session && !reopened.isClosed)
            let closedAgain = await reopened.flushForClose()
            #expect(closedAgain)
        } catch { await session.presentationEnded(); throw error }
        await session.presentationEnded()
    }
}
#endif
