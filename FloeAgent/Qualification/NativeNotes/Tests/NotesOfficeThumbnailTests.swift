// SPDX-License-Identifier: MPL-2.0
//
// Targeted checks for the `--preview-fixture` Office thumbnail qualification
// host. They assert that the fixtures are real, inspectable OOXML packages and
// that the same files `NotesDocumentThumbnail` would stage are readable by the
// system Quick Look generator. They do not modify product code: the view's
// private generation path is exercised through the page's shared factory and
// the public Quick Look API only.
import XCTest
import UIKit
import QuickLookThumbnailing
import FloeNotes
import FloeDocuments
@testable import FloeNotesNativeQualification

@MainActor
final class NotesOfficeThumbnailTests: XCTestCase {
    private func makeScratchDirectory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-office-thumb-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    /// Every sample must be a genuine Office package that the shared importer
    /// accepts as an `.office` document pointing at an intact CAS resource.
    func testPreviewFixtureFactoryImportsRealOfficeDocuments() async throws {
        let root = makeScratchDirectory("import")
        defer { try? FileManager.default.removeItem(at: root) }

        let samples = PreviewFixtureFactory.samples
        XCTAssertGreaterThanOrEqual(Set(samples.map(\.format)).count, 3, "All three Office formats must be represented")

        let urls = try PreviewFixtureFactory.writeSamples(to: root.appendingPathComponent("sources"))
        XCTAssertEqual(urls.count, samples.count)

        let expectedKinds: [PreviewFixtureSample.Format: OfficeDocumentKind] = [
            .word: .word, .excel: .workbook, .powerpoint: .presentation
        ]
        for (sample, url) in zip(samples, urls) {
            let snapshot = try OfficeDocumentService.inspect(url: url)
            XCTAssertEqual(snapshot.kind, expectedKinds[sample.format])
            XCTAssertGreaterThan(snapshot.packageBytes, 0)
            XCTAssertFalse(snapshot.fields.isEmpty, "\(sample.fileName) has no inspectable content")
        }

        let store = try NotesStore(root: root.appendingPathComponent("store"))
        var imported: [NoteDocument] = []
        for url in urls {
            let draft = try await NoteFileImporter.importFile(url, notebookID: nil, store: store)
            imported.append(try await store.create(draft))
        }
        XCTAssertEqual(imported.count, samples.count)

        let extensions = Set(imported.compactMap { document in
            document.officeFileName.map { ($0 as NSString).pathExtension.lowercased() }
        })
        XCTAssertEqual(extensions, ["docx", "xlsx", "pptx"])

        for (document, url) in zip(imported, urls) {
            XCTAssertEqual(document.kind, .office)
            let resourceID = try XCTUnwrap(document.officeResourceID)
            XCTAssertEqual(document.officeFileName, url.lastPathComponent)
            let resource = try await store.resourceURL(resourceID)
            XCTAssertEqual(try Data(contentsOf: resource), try Data(contentsOf: url),
                           "The thumbnail source must be the exact generated package")
        }
    }

    /// The view stages a copy with a validated extension and asks Quick Look for
    /// a real representation. This test performs the same request. When the host
    /// OS has no Office generator the check is skipped rather than falsely
    /// passing; a returned image must be non-empty.
    func testQuickLookCanRenderGeneratedOfficeFixtures() async throws {
        let root = makeScratchDirectory("quicklook")
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try PreviewFixtureFactory.writeSamples(to: root.appendingPathComponent("sources"))

        var rendered: [String] = []
        var missing: [String] = []
        for url in urls {
            if let image = await Self.quickLookThumbnail(for: url) {
                XCTAssertGreaterThan(image.size.width, 0)
                XCTAssertGreaterThan(image.size.height, 0)
                XCTAssertNotNil(image.cgImage)
                rendered.append(url.lastPathComponent)
            } else {
                missing.append(url.lastPathComponent)
            }
        }

        if rendered.isEmpty {
            throw XCTSkip("此环境没有可用于 Office 文件的 Quick Look 缩略图生成器，未生成：\(missing.joined(separator: ", "))")
        }
        XCTAssertTrue(missing.isEmpty, "Quick Look failed to render: \(missing.joined(separator: ", "))")
        XCTAssertEqual(rendered.count, urls.count)
        // Partial Office support must not qualify all three document formats.
        print("QuickLook rendered: \(rendered.joined(separator: ", "))")
    }

    /// Mirrors `NotesDocumentThumbnail` staging: Quick Look needs the validated
    /// extension, so a uniquely scoped copy is requested instead of the CAS path.
    private static func quickLookThumbnail(for source: URL, size: CGSize = CGSize(width: 320, height: 420)) async -> UIImage? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-office-thumb-stage-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch { return nil }
        defer { try? FileManager.default.removeItem(at: directory) }

        let copy = directory.appendingPathComponent("preview.\(source.pathExtension.lowercased())")
        do { try FileManager.default.copyItem(at: source, to: copy) } catch { return nil }

        let request = QLThumbnailGenerator.Request(fileAt: copy, size: size, scale: 1,
                                                   representationTypes: .thumbnail)
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.uiImage)
            }
        }
    }
}
