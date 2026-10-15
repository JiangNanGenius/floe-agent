// FloeNotesTests — explicit custom cover contract (job-3d1d4048e9a34730, lane N).
//
// Covers the store/model half of the custom-cover feature: persistence and
// reopen, priority over the automatic mode, content edits and undo never touch
// the cover, restore-automatic, stale/invalid inputs fail closed, cover-revision
// compare-and-swap (manual vs assistant races), the atomic assistant scope
// re-check, resource reference safety (journaled collection, discard guard,
// undo retention), the real bounded raster processor (PNG/HEIC/corrupt/SVG) and
// the archive round trip with a remapped cover resource.
import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import FloeNotes

@Suite("Notes custom cover")
struct NoteCoverStoreTests {
    /// One valid 1x1 PNG. The store treats a cover as raw immutable bytes; a
    /// real image is used so the fixture matches the product ingestion path.
    private static let tinyPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    private func makeStore(_ label: String) throws -> (NotesStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-cover-\(label)-\(UUID().uuidString)", isDirectory: true)
        return (try NotesStore(root: root), root)
    }

    private func makeDocument(_ store: NotesStore, title: String = "封面文档") async throws -> NoteDocument {
        var document = NoteDocument(title: title)
        document.pages[0].elements = [NoteElement(frame: .init(x: 20, y: 20, width: 320, height: 80), text: "正文内容")]
        return try await store.create(document)
    }

    /// Import a raw fixture resource. Media type is caller-declared exactly like
    /// `NotesStore.importResource` records it; the cover surface additionally
    /// checks it is a stored cover format, and the processor checks real bytes.
    private func importAsset(_ store: NotesStore, mediaType: String = "image/png",
                             data: Data = tinyPNG, extension ext: String = "png") async throws -> UUID {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("note-cover-\(UUID().uuidString).\(ext)")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await store.importResource(from: url, mediaType: mediaType)
    }

    private func installCover(_ store: NotesStore, document: NoteDocument, resource: UUID,
                              expectedCoverRevision: Int) async throws -> NoteDocument {
        try await store.applyCoverCommand(.useResource(resource), documentID: document.id,
                                          expectedRevision: document.revision,
                                          expectedCoverRevision: expectedCoverRevision)
    }

    // MARK: persistence and priority

    @Test("custom cover persists across reopen and always reports custom mode")
    func coverPersistsAcrossReopen() async throws {
        let (store, root) = try makeStore("reopen")
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await makeDocument(store)
        let resource = try await importAsset(store)
        #expect(document.coverMode == .automatic)
        #expect(document.coverResourceID == nil)
        #expect(document.normalizedCoverRevision == 0)
        #expect(document.resourceIDs.contains(resource) == false)

        let updated = try await installCover(store, document: document, resource: resource, expectedCoverRevision: 0)
        #expect(updated.coverResourceID == resource)
        #expect(updated.coverRevision == 1)
        #expect(updated.coverMode == .custom(resource))
        #expect(updated.resourceIDs.contains(resource))
        // A cover write is not a content edit.
        #expect(updated.revision == document.revision)

        let second = try NotesStore(root: root)
        let value = try await second.document(document.id)
        #expect(value.coverResourceID == resource)
        #expect(value.coverRevision == 1)
        #expect(value.coverMode == .custom(resource))
    }

    @Test("cover cache token changes only with the cover, never with the content revision")
    func coverCacheTokenIndependentOfContentRevision() async throws {
        let (store, root) = try makeStore("token")
        defer { try? FileManager.default.removeItem(at: root) }
        var document = try await makeDocument(store)
        let automaticToken = document.coverCacheToken

        let resource = try await importAsset(store)
        document = try await installCover(store, document: document, resource: resource, expectedCoverRevision: 0)
        let customToken = document.coverCacheToken
        #expect(customToken != automaticToken)

        document = try await store.apply(.init(documentID: document.id, expectedRevision: document.revision,
                                               title: "重命名", edits: [.rename("重命名")]))
        #expect(document.revision > 1)
        #expect(document.coverCacheToken == customToken, "content revision must not move the cover token")

        document = try await store.applyCoverCommand(.restoreAutomatic, documentID: document.id,
                                                     expectedRevision: document.revision,
                                                     expectedCoverRevision: 1)
        #expect(document.coverResourceID == nil)
        #expect(document.coverRevision == 2)
        #expect(document.coverCacheToken != automaticToken, "restored automatic cover needs a fresh key")
        #expect(document.coverCacheToken != customToken)
    }

    // MARK: content edits, undo, restore

    @Test("content edit and undo keep the explicit cover and its version")
    func contentEditAndUndoKeepCover() async throws {
        let (store, root) = try makeStore("undo")
        defer { try? FileManager.default.removeItem(at: root) }
        var document = try await makeDocument(store)
        let resource = try await importAsset(store)
        document = try await installCover(store, document: document, resource: resource, expectedCoverRevision: 0)
        let coverToken = document.coverCacheToken

        let edited = try await store.apply(.init(documentID: document.id, expectedRevision: document.revision,
                                                 title: "编辑", edits: [.rename("编辑")]))
        #expect(edited.coverResourceID == resource)
        #expect(edited.coverRevision == 1)

        let undone = try await store.undo(document.id, expectedRevision: edited.revision)
        #expect(undone.title == "封面文档")
        #expect(undone.coverResourceID == resource, "undo must not rewind the cover")
        #expect(undone.coverCacheToken == coverToken)
        #expect(undone.revision == edited.revision + 1)
    }

    @Test("restore automatic is idempotent and keeps the content revision")
    func restoreAutomaticClearsAndIsIdempotent() async throws {
        let (store, root) = try makeStore("restore")
        defer { try? FileManager.default.removeItem(at: root) }
        var document = try await makeDocument(store)
        let resource = try await importAsset(store)
        document = try await installCover(store, document: document, resource: resource, expectedCoverRevision: 0)
        let revision = document.revision

        let restored = try await store.applyCoverCommand(.restoreAutomatic, documentID: document.id,
                                                         expectedRevision: revision,
                                                         expectedCoverRevision: 1)
        #expect(restored.coverResourceID == nil)
        #expect(restored.coverRevision == 2)
        #expect(restored.revision == revision)

        // Retrying the settled state is a no-op even with a now-stale cover version.
        let repeated = try await store.applyCoverCommand(.restoreAutomatic, documentID: document.id,
                                                         expectedRevision: revision,
                                                         expectedCoverRevision: 1)
        #expect(repeated.coverRevision == 2)
        #expect(repeated.coverCacheToken == restored.coverCacheToken)
    }

    // MARK: cover-revision compare-and-swap

    @Test("two cover edits from the same content revision cannot both succeed")
    func coverRevisionCompareAndSwapRejectsSecondWriter() async throws {
        let (store, root) = try makeStore("cas")
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await makeDocument(store)
        let first = try await importAsset(store, data: Self.distinctPNG(1))
        let second = try await importAsset(store, data: Self.distinctPNG(2))

        let afterFirst = try await installCover(store, document: document, resource: first, expectedCoverRevision: 0)
        #expect(afterFirst.coverResourceID == first)
        #expect(afterFirst.coverRevision == 1)

        // Both writers read coverRevision 0 and the same content revision; the
        // second write must fail closed instead of silently replacing the cover.
        await #expect(throws: (any Error).self) {
            try await store.applyCoverCommand(.useResource(second), documentID: document.id,
                                              expectedRevision: document.revision, expectedCoverRevision: 0)
        }
        var value = try await store.document(document.id)
        #expect(value.coverResourceID == first)
        #expect(value.coverRevision == 1)

        // A restore from the same stale baseline is refused too.
        await #expect(throws: (any Error).self) {
            try await store.applyCoverCommand(.restoreAutomatic, documentID: document.id,
                                              expectedRevision: document.revision, expectedCoverRevision: 0)
        }
        value = try await store.document(document.id)
        #expect(value.coverResourceID == first)

        // The writer that re-reads the current cover revision succeeds.
        let afterSecond = try await store.applyCoverCommand(.useResource(second), documentID: document.id,
                                                            expectedRevision: document.revision,
                                                            expectedCoverRevision: 1)
        #expect(afterSecond.coverResourceID == second)
        #expect(afterSecond.coverRevision == 2)
    }

    @Test("assistant apply re-checks the editing grant inside the cover write transaction")
    func revokeBetweenPrepareAndCommitFailsClosed() async throws {
        let (store, root) = try makeStore("revoke")
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await makeDocument(store)
        let resource = try await importAsset(store)
        let conversation = UUID()
        try await store.bindAssistant(conversationID: conversation, documentID: document.id, canEdit: true)
        // The pre-check (what the tool does before the async image import) passes.
        try await store.authorize(conversationID: conversation, documentID: document.id, editing: true)
        // A native revoke lands while the import is in flight.
        try await store.revokeAccess(conversationID: conversation, documentID: document.id)

        await #expect(throws: (any Error).self) {
            try await store.applyCoverCommand(.useResource(resource), documentID: document.id,
                                              expectedRevision: document.revision, expectedCoverRevision: 0,
                                              authorizedConversationID: conversation)
        }
        let value = try await store.document(document.id)
        #expect(value.coverResourceID == nil, "a revoked grant must win at commit")

        // The assistant service path (pre-check + atomic re-check) also fails closed.
        await #expect(throws: (any Error).self) {
            try await NotesCoverCommandService.apply(.useResource(resource), conversationID: conversation,
                                                     documentID: document.id, expectedRevision: document.revision,
                                                     expectedCoverRevision: 0, store: store)
        }
        try await store.grantAccess(conversationID: conversation, documentID: document.id, canEdit: true)
        let updated = try await NotesCoverCommandService.apply(.useResource(resource), conversationID: conversation,
                                                               documentID: document.id,
                                                               expectedRevision: document.revision,
                                                               expectedCoverRevision: 0, store: store)
        #expect(updated.coverResourceID == resource)
    }

    // MARK: stale and invalid inputs

    @Test("a stale content revision is rejected and leaves the cover untouched")
    func staleContentRevisionFailsClosed() async throws {
        let (store, root) = try makeStore("stale")
        defer { try? FileManager.default.removeItem(at: root) }
        var document = try await makeDocument(store)
        let first = try await importAsset(store, data: Self.distinctPNG(3))
        let second = try await importAsset(store, data: Self.distinctPNG(4))
        document = try await installCover(store, document: document, resource: first, expectedCoverRevision: 0)
        let staleRevision = document.revision

        document = try await store.apply(.init(documentID: document.id, expectedRevision: document.revision,
                                               title: "并发编辑", edits: [.rename("并发编辑")]))
        await #expect(throws: (any Error).self) {
            try await store.applyCoverCommand(.useResource(second), documentID: document.id,
                                              expectedRevision: staleRevision, expectedCoverRevision: 1)
        }
        let value = try await store.document(document.id)
        #expect(value.coverResourceID == first, "a stale result must not replace the prior cover")
        #expect(value.coverRevision == 1)
    }

    @Test("the store only accepts the two normalized stored cover formats")
    func storedCoverFormatsOnly() async throws {
        let (store, root) = try makeStore("formats")
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await makeDocument(store)

        for (mediaType, ext) in [("text/plain", "txt"), ("image/svg+xml", "svg"),
                                 ("image/heic", "heic"), ("application/pdf", "pdf")] {
            let resource = try await importAsset(store, mediaType: mediaType,
                                                 data: Data("not a cover \(mediaType)".utf8), extension: ext)
            await #expect(throws: (any Error).self) {
                try await store.applyCoverCommand(.useResource(resource), documentID: document.id,
                                                  expectedRevision: document.revision, expectedCoverRevision: 0)
            }
        }
        #expect(try await store.document(document.id).coverResourceID == nil)

        let jpeg = try await importAsset(store, mediaType: "image/jpeg", data: Self.distinctPNG(5), extension: "jpg")
        let png = try await importAsset(store, mediaType: "image/png")
        let acceptedJPEG = try await store.applyCoverCommand(.useResource(jpeg), documentID: document.id,
                                                             expectedRevision: document.revision,
                                                             expectedCoverRevision: 0)
        #expect(acceptedJPEG.coverResourceID == jpeg)
        let acceptedPNG = try await store.applyCoverCommand(.useResource(png), documentID: document.id,
                                                            expectedRevision: document.revision,
                                                            expectedCoverRevision: 1)
        #expect(acceptedPNG.coverResourceID == png)
    }

    @Test("a trashed document cannot change its cover")
    func trashedDocumentRejected() async throws {
        let (store, root) = try makeStore("trashed")
        defer { try? FileManager.default.removeItem(at: root) }
        var document = try await makeDocument(store)
        let image = try await importAsset(store)
        document = try await installCover(store, document: document, resource: image, expectedCoverRevision: 0)
        let trashed = try await store.setTrashed(document.id, expectedRevision: document.revision, trashed: true)
        await #expect(throws: (any Error).self) {
            try await store.applyCoverCommand(.restoreAutomatic, documentID: document.id,
                                              expectedRevision: trashed.revision, expectedCoverRevision: 1)
        }
        #expect(try await store.document(document.id).coverResourceID == image)
    }

    // MARK: reference safety

    @Test("replaced and cleared covers are collected; a cover kept by undo history survives")
    func coverResourceCollection() async throws {
        let (_, root) = try makeStore("collection")
        defer { try? FileManager.default.removeItem(at: root) }
        var documentID: UUID?
        var first: UUID?
        var second: UUID?
        do {
            let store = try NotesStore(root: root)
            var document = try await makeDocument(store)
            let firstAsset = try await importAsset(store, data: Self.distinctPNG(6))
            let secondAsset = try await importAsset(store, data: Self.distinctPNG(7))
            document = try await installCover(store, document: document, resource: firstAsset, expectedCoverRevision: 0)
            // A content edit after the cover makes undo history reference `first`.
            document = try await store.apply(.init(documentID: document.id, expectedRevision: document.revision,
                                                   title: "编辑", edits: [.rename("编辑")]))
            document = try await store.applyCoverCommand(.useResource(secondAsset), documentID: document.id,
                                                         expectedRevision: document.revision,
                                                         expectedCoverRevision: 1)
            document = try await store.applyCoverCommand(.restoreAutomatic, documentID: document.id,
                                                         expectedRevision: document.revision,
                                                         expectedCoverRevision: 2)
            documentID = document.id; first = firstAsset; second = secondAsset
        }
        // A store's issued URLs stay pinned for its lifetime, so collection is
        // observed from a fresh store instance (the documented reopen contract).
        let collector = try NotesStore(root: root)
        _ = try await collector.collectDeletedResources()
        let value = try await collector.document(documentID!)
        #expect(value.coverResourceID == nil)
        _ = try await collector.resourceURL(first!) // history still references it
        var secondRemoved = false
        do { _ = try await collector.resourceURL(second!) } catch { secondRemoved = true }
        #expect(secondRemoved, "an unreferenced cleared cover must be collectable")
    }

    @Test("discardUnreferencedResource removes only a fresh unreferenced import")
    func discardOnlyUnreferencedImports() async throws {
        let (store, root) = try makeStore("discard")
        defer { try? FileManager.default.removeItem(at: root) }
        var document = try await makeDocument(store)

        // A fresh import that never became a cover is removed.
        let orphan = try await importAsset(store, data: Self.distinctPNG(8))
        #expect(try await store.discardUnreferencedResource(orphan))
        var orphanRemoved = false
        do { _ = try await store.resourceURL(orphan) } catch { orphanRemoved = true }
        #expect(orphanRemoved)

        // A referenced cover resource is retained even when its id is passed
        // again (content-addressed re-import of the same bytes).
        let cover = try await importAsset(store, data: Self.distinctPNG(9))
        document = try await installCover(store, document: document, resource: cover, expectedCoverRevision: 0)
        // Re-import the SAME bytes: the content-addressed store must dedupe
        // to the one existing resource id.
        let sameBytes = try await importAsset(store, data: Self.distinctPNG(9))
        #expect(sameBytes == cover, "identical bytes dedup to one content-addressed resource")
        #expect(try await store.discardUnreferencedResource(cover) == false)
        _ = try await store.resourceURL(cover)

        // A resource referenced only by undo history is retained too.
        document = try await store.apply(.init(documentID: document.id, expectedRevision: document.revision,
                                               title: "编辑", edits: [.rename("编辑")]))
        _ = try await store.discardUnreferencedResource(cover)
        #expect(try await store.discardUnreferencedResource(cover) == false)
    }

    @Test("a .floenote archive round trip keeps a remapped custom cover")
    func archiveRoundTripRemapsCover() async throws {
        let (source, sourceRoot) = try makeStore("archive-source")
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        var document = try await makeDocument(source, title: "归档封面")
        let resource = try await importAsset(source)
        document = try await installCover(source, document: document, resource: resource, expectedCoverRevision: 0)

        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("note-cover-\(UUID().uuidString).floenote")
        defer { try? FileManager.default.removeItem(at: archive) }
        try await NotesArchive.export(document: document, store: source, to: archive)

        let (destination, destinationRoot) = try makeStore("archive-destination")
        defer { try? FileManager.default.removeItem(at: destinationRoot) }
        let imported = try await NotesArchive.importDocument(from: archive, notebookID: nil, store: destination)
        #expect(imported.coverResourceID != nil)
        #expect(imported.coverResourceID != resource, "the imported cover is its own resource")
        #expect(imported.coverRevision == 1)
        #expect(imported.resourceIDs.contains(imported.coverResourceID!))
        _ = try await destination.resourceURL(imported.coverResourceID!)
    }

    // MARK: real bounded raster processor

    @Test("the processor normalizes a real PNG into a stored cover format")
    func processorNormalizesValidPNG() throws {
        let normalized = try NotesCoverImageProcessor.normalizedCoverData(Self.tinyPNG)
        #expect(NoteCoverAssetPolicy.acceptsStoredAsset(mediaType: normalized.mediaType))
        #expect(normalized.data.isEmpty == false)
        #expect(NoteCoverAssetPolicy.accepts(byteCount: normalized.data.count))
        #expect(CGImageSourceCreateWithData(normalized.data as CFData, nil) != nil, "normalized bytes must decode")
    }

    @Test("the processor rejects corrupt bytes and vector input")
    func processorRejectsCorruptAndVector() {
        #expect(throws: (any Error).self) {
            _ = try NotesCoverImageProcessor.normalizedCoverData(Data("this is not an image".utf8))
        }
        let svg = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>
        """.utf8)
        #expect(throws: (any Error).self) {
            _ = try NotesCoverImageProcessor.normalizedCoverData(svg)
        }
    }

    @Test("the processor rejects an oversized dimension and accepts a real HEIC when the host encodes it")
    func processorBoundsAndHEIC() throws {
        // A small file with a 20,001-pixel dimension is rejected before decode.
        if let oversized = Self.makePNG(width: NoteCoverAssetPolicy.maximumDimension + 1, height: 1) {
            #expect(throws: (any Error).self) {
                _ = try NotesCoverImageProcessor.normalizedCoverData(oversized)
            }
        } else {
            Issue.record("could not generate the oversized fixture")
        }

        // HEIC availability is host-dependent; when the host encodes it the
        // processor must convert it to a stored format rather than reject it.
        guard let heic = Self.makeHEIC(width: 8, height: 8) else { return }
        let normalized = try NotesCoverImageProcessor.normalizedCoverData(heic)
        #expect(NoteCoverAssetPolicy.acceptsStoredAsset(mediaType: normalized.mediaType))
        #expect(CGImageSourceCreateWithData(normalized.data as CFData, nil) != nil)
    }

    @Test("validatedCoverResource converts a HEIC resource and refuses corrupt bytes")
    func validatedResourceConversionAndRefusal() async throws {
        let (store, root) = try makeStore("validated")
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await makeDocument(store)

        // The cover that the successful HEIC conversion settled on; the
        // refused corrupt request must leave exactly this cover in place.
        var expectedCover: UUID?
        if let heic = Self.makeHEIC(width: 8, height: 8) {
            let heicResource = try await importAsset(store, mediaType: "image/heic", data: heic, extension: "heic")
            let validated = try await NotesCoverImageProcessor.validatedCoverResource(heicResource, store: store)
            #expect(validated != heicResource, "HEIC is normalized to a new stored-format resource")
            #expect(NoteCoverAssetPolicy.acceptsStoredAsset(mediaType: try await store.resourceMediaType(validated)))
            _ = try await store.resourceURL(heicResource) // the original vector/raster source is untouched
            let updated = try await store.applyCoverCommand(.useResource(validated), documentID: document.id,
                                                            expectedRevision: document.revision,
                                                            expectedCoverRevision: 0)
            #expect(updated.coverResourceID == validated)
            expectedCover = validated
        }

        let corrupt = try await importAsset(store, mediaType: "image/png", data: Data("corrupt".utf8))
        await #expect(throws: (any Error).self) {
            _ = try await NotesCoverImageProcessor.validatedCoverResource(corrupt, store: store)
        }
        let readBack = try await store.document(document.id)
        #expect(readBack.coverResourceID == expectedCover,
                "the refused corrupt request must not change the settled cover")
    }

    // MARK: migration defaults and bounds

    @Test("documents written before custom covers decode with no cover and pass validation")
    func legacyDocumentDecodesWithNilCover() throws {
        var legacy = NoteDocument(title: "旧文档")
        legacy.pages[0].elements = [NoteElement(frame: .init(x: 1, y: 1, width: 10, height: 10), text: "旧内容")]
        let data = try JSONEncoder().encode(legacy)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("encoded document is not a JSON object")
            return
        }
        object.removeValue(forKey: "coverResourceID")
        object.removeValue(forKey: "coverRevision")
        let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        let decoded = try JSONDecoder().decode(NoteDocument.self, from: legacyData)
        #expect(decoded.coverResourceID == nil)
        #expect(decoded.coverRevision == nil)
        #expect(decoded.normalizedCoverRevision == 0)
        #expect(decoded.coverMode == .automatic)
        #expect(decoded.coverCacheToken == "auto@0")
        #expect(throws: Never.self) { try decoded.validate() }
    }

    @Test("cover asset policy classifies images and stored formats separately")
    func assetPolicyBounds() {
        #expect(NoteCoverAssetPolicy.isImageMediaType("image/png"))
        #expect(NoteCoverAssetPolicy.isImageMediaType("IMAGE/HEIC"))
        #expect(NoteCoverAssetPolicy.isImageMediaType("image/svg+xml"))
        #expect(NoteCoverAssetPolicy.isImageMediaType("text/plain") == false)
        #expect(NoteCoverAssetPolicy.isImageMediaType(nil) == false)

        #expect(NoteCoverAssetPolicy.acceptsStoredAsset(mediaType: "image/png"))
        #expect(NoteCoverAssetPolicy.acceptsStoredAsset(mediaType: "image/jpeg"))
        #expect(NoteCoverAssetPolicy.acceptsStoredAsset(mediaType: "image/heic") == false)
        #expect(NoteCoverAssetPolicy.acceptsStoredAsset(mediaType: "image/svg+xml") == false)
        #expect(NoteCoverAssetPolicy.acceptsStoredAsset(mediaType: nil) == false)

        #expect(NoteCoverAssetPolicy.accepts(byteCount: 1))
        #expect(NoteCoverAssetPolicy.accepts(byteCount: NoteCoverAssetPolicy.maximumBytes))
        #expect(NoteCoverAssetPolicy.accepts(byteCount: NoteCoverAssetPolicy.maximumBytes + 1) == false)
        #expect(NoteCoverAssetPolicy.accepts(byteCount: 0) == false)

        #expect(NoteCoverAssetPolicy.accepts(pixelWidth: 800, pixelHeight: 600))
        #expect(NoteCoverAssetPolicy.accepts(pixelWidth: NoteCoverAssetPolicy.maximumDimension, pixelHeight: 1))
        #expect(NoteCoverAssetPolicy.accepts(pixelWidth: 0, pixelHeight: 10) == false)
        #expect(NoteCoverAssetPolicy.accepts(pixelWidth: 100_000, pixelHeight: 100_000) == false)
        #expect(NoteCoverAssetPolicy.accepts(pixelWidth: Int.max, pixelHeight: 2) == false)
    }

    // MARK: fixtures

    /// Distinct valid PNG bytes for tests that need two different resources
    /// (the store is content-addressed, so identical bytes dedup to one id).
    private static func distinctPNG(_ seed: Int) -> Data {
        makePNG(width: 2 + seed, height: 2 + seed) ?? tinyPNG
    }

    private static func makePNG(width: Int, height: Int) -> Data? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func makeHEIC(width: Int, height: Int) -> Data? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
