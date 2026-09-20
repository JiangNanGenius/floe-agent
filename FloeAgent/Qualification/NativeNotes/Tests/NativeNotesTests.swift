// SPDX-License-Identifier: MPL-2.0
import XCTest
import AVFoundation
import UIKit
import PencilKit
import SwiftUI
import FloeNotes
import FloeDocuments
@testable import FloeNotesNativeQualification

@MainActor final class NativeNotesTests: XCTestCase {
    func testScannedBilingualPageUsesRealVisionAndBecomesSearchable() async throws {
        // Functional OCR/search qualification, not a latency benchmark. Run
        // 35301809882 returned correct text at 138 s on the cold iPhone simulator
        // after the default allowance rounded to 120 s. Use the existing 180 s
        // workflow ceiling for this case only; retain timing evidence below.
        executionTimeAllowance = 180
        let started = ContinuousClock.now
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        // Qualification fixture must be device-independent: UIGraphicsImageRenderer's
        // default format tracks the display scale (3x on iPhone -> 2304x3072 PNG,
        // 2x on iPad -> 1536x2048 PNG in the build 185/186 artifacts). Pin 2x so both
        // device families feed the same real Vision input and the same importer path.
        let fixtureFormat = UIGraphicsImageRendererFormat()
        fixtureFormat.scale = 2
        let image = UIGraphicsImageRenderer(size: CGSize(width: 768, height: 1024), format: fixtureFormat).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 768, height: 1024))
            ("边际成本\nOpportunity cost\nEnglish and Chinese" as NSString).draw(in: CGRect(x: 40, y: 80, width: 680, height: 500), withAttributes: [.font: UIFont.systemFont(ofSize: 42), .foregroundColor: UIColor.black])
        }
        let file = root.appendingPathComponent("scan.png"); try XCTUnwrap(image.pngData()).write(to: file)
        let imported = try await NoteFileImporter.importFile(file, notebookID: nil, store: store)
        let document = try await store.create(imported)
        let page = try XCTUnwrap(document.pages.first)
        let text = try await NoteFileImporter.visualSearchText(page: page, store: store)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("opportunity"), text)
        XCTAssertTrue(text.replacingOccurrences(of: " ", with: "").contains("边际成本"), text)
        try await store.cachePageOCR(documentID: document.id, pageID: page.id, sourceKey: page.visualIndexKey, text: text, error: nil)
        let hits = try await store.search("Opportunity")
        XCTAssertEqual(hits.map(\.id), [document.id])
        let attachment = XCTAttachment(image: image); attachment.name = "bilingual-scanned-page-original"; attachment.lifetime = .keepAlways; add(attachment)
        let output = XCTAttachment(string: text); output.name = "bilingual-Vision-OCR-output"; output.lifetime = .keepAlways; add(output)
        let timing = XCTAttachment(string: "functional OCR/search elapsed: \(started.duration(to: .now)); fixture: 1536x2048 pixels; allowance: 180 seconds")
        timing.name = "bilingual-Vision-OCR-timing"; timing.lifetime = .keepAlways; add(timing)
    }

    func testWorkspaceOfficeAndTextImportsIndexContents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let file = root.appendingPathComponent("generated.docx")
        try OfficeDocumentBuilder.createWord(at: file, title: "Unrelated title", paragraphs: ["边际成本与 opportunity cost"])
        let imported = try await NoteFileImporter.importFile(file, notebookID: nil, store: store)
        let office = try await store.create(imported)
        let extracted = try await NoteFileImporter.officeSearchText(url: file)
        try await store.cacheOfficeText(documentID: office.id, resourceID: try XCTUnwrap(office.officeResourceID), text: extracted, error: nil)
        let hits = try await store.search("边际成本")
        XCTAssertEqual(hits.map(\.id), [office.id])
        let markdown = root.appendingPathComponent("generated.md")
        let source = String(repeating: "中文段落 and English text\n", count: 150)
        try source.write(to: markdown, atomically: true, encoding: .utf8)
        let note = try await NoteFileImporter.importFile(markdown, notebookID: nil, store: store)
        XCTAssertGreaterThan(note.pages.count, 1)
        XCTAssertEqual(note.pages.flatMap(\.elements).map(\.text).joined(), source)
        XCTAssertTrue(note.pages.flatMap(\.elements).allSatisfy { !$0.isAIGenerated })
    }

    func testSourceNavigationKeepsMapSessionAndRejectsMissingPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let parent = try await store.create(NoteDocument(kind: .notebook, title: "课件"))
        let map = try await store.create(NoteDocument(kind: .mindMap, title: "导图"))
        let reader = NotesSession(), window = NotesSession()
        await reader.open(using: store); await window.open(using: store)
        await reader.select(map); await window.select(map)
        let source = NoteSourceReference(documentID: parent.id, revision: parent.revision, pageID: parent.pages[0].id)
        let opened = await reader.openSource(source)
        XCTAssertTrue(opened)
        XCTAssertEqual(reader.document?.id, parent.id)
        XCTAssertEqual(reader.requestedPageID, parent.pages[0].id)
        XCTAssertEqual(window.document?.id, map.id)
        let invalid = NoteSourceReference(documentID: map.id, revision: map.revision, pageID: UUID())
        let rejected = await reader.openSource(invalid)
        XCTAssertFalse(rejected)
        XCTAssertEqual(reader.document?.id, parent.id, "An invalid source must leave the current reader in place")
        let unchanged = try await store.document(map.id)
        XCTAssertEqual(unchanged.revision, map.revision)
    }

    func testLinkedMapWindowRendersOverPDFAndRetainsSeparateUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let pdfURL = root.appendingPathComponent("Economics.pdf")
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 768, height: 1024)).pdfData { context in
            context.beginPage()
            ("国际经济学 · International Economics" as NSString).draw(at: CGPoint(x: 48, y: 64), withAttributes: [.font: UIFont.systemFont(ofSize: 28, weight: .bold)])
            ("Lecture 03 — Comparative advantage\n\n机会成本与贸易收益\n\n两国可以通过专业化分工提高总产出。\nCompare the opportunity cost before choosing a strategy." as NSString)
                .draw(in: CGRect(x: 48, y: 130, width: 660, height: 500), withAttributes: [.font: UIFont.systemFont(ofSize: 22)])
        }
        try pdf.write(to: pdfURL)
        let imported = try await NoteFileImporter.importFile(pdfURL, notebookID: nil, store: store)
        let parent = try await store.create(imported)
        var map = try await store.createLinkedMindMap(parentID: parent.id, expectedRevision: parent.revision, title: "比较优势", pageID: parent.pages[0].id)
        let children = [MindMapNode(parentID: map.nodes[0].id, title: "机会成本", order: 0), MindMapNode(parentID: map.nodes[0].id, title: "Trade gains", order: 1)]
        map = try await store.apply(.init(documentID: map.id, expectedRevision: map.revision, title: "Add topics", edits: children.map(NoteEdit.upsertNode)))
        let session = NotesSession()
        await session.open(using: store)
        await session.select(parent)
        let current = try XCTUnwrap(session.document)
        let link = try XCTUnwrap(current.linkedMindMaps?.first)
        let background = try await NoteFileImporter.background(page: parent.pages[0], store: store)
        let host = UIHostingController(rootView: VStack(spacing: 0) {
            HStack { Text("国际经济学 · 课件与导图").font(.headline); Spacer(); Text("第 1 页").foregroundStyle(.secondary) }.padding()
            ZStack {
                NotePencilView(page: parent.pages[0], drawing: nil, background: background, fingerDrawing: false,
                               tool: PKInkingTool(.pen, color: .black, width: 3), onDrawing: { _ in })
                NotesMindMapWindow(parentSession: session, parentID: parent.id, link: link, close: {}, onAssistant: { _ in }).padding(12)
            }
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        host.view.layoutIfNeeded()
        // The native surface must render both topics without any WebKit view.
        let labels = await waitForAccessibilityTexts(in: host.view, containing: ["Trade gains", "机会成本"])
        XCTAssertTrue(labels.contains(where: { $0.contains("Trade gains") }) && labels.contains(where: { $0.contains("机会成本") }),
                      "The independently stored map must render inside the PDF reader window; labels: \(labels)")
        XCTAssertFalse(viewHierarchyContainsWebView(host.view), "The linked map window must not embed a WebKit surface")
        let content = XCTAttachment(image: snapshot(host.view))
        content.name = "Notes linked map — native content evidence"
        content.lifetime = .keepAlways; add(content)
        let mapBefore = try await store.document(map.id)
        await session.select(try await store.document(parent.id))
        session.undo()
        // Wait for the parent session's serialized undo to complete.
        await session.select(try await store.document(parent.id))
        let parentAfter = try await store.document(parent.id)
        XCTAssertTrue(parentAfter.linkedMindMaps?.isEmpty != false)
        let mapAfter = try await store.document(map.id)
        XCTAssertEqual(mapAfter, mapBefore, "Undoing the parent association must not undo map edits")
    }

    func testCaptionExportsPreserveTimingAndEscapeSourceMarkup() throws {
        let segments = [TimedSpeechSegment(start: 1.125, end: 3.5, text: "普通话 <English> & 123", words: [])]
        let srt = String(decoding: try SpeechCaptionExport.data(segments: segments, format: "srt"), as: UTF8.self)
        XCTAssertTrue(srt.contains("00:00:01,125 --> 00:00:03,500"))
        XCTAssertTrue(srt.contains("普通话 &lt;English&gt; &amp; 123"))
        let vtt = String(decoding: try SpeechCaptionExport.data(segments: segments, format: "vtt"), as: UTF8.self)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(vtt.contains("00:00:01.125 --> 00:00:03.500"))
        let reopened = try JSONDecoder().decode([TimedSpeechSegment].self, from: SpeechCaptionExport.data(segments: segments, format: "json"))
        XCTAssertEqual(reopened.first?.text, segments.first?.text)
        XCTAssertEqual(reopened.first?.start, 1.125)
    }

    func testSpeechChunkResamplesStereoAndPreservesDelayedTrackTiming() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("stereo.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
            buffer.frameLength = 48000
            for channel in 0..<2 {
                let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
                for index in 0..<48000 { samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 48000) * 0.4) }
            }
            try file.write(from: buffer)
        }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let sourceTrack = try XCTUnwrap(tracks.first)
        let composition = AVMutableComposition()
        let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 48000)),
                                  of: sourceTrack, at: CMTime(seconds: 2, preferredTimescale: 48000))
        let samples = try SpeechAudioChunk.read(asset: composition, track: track, start: 0, duration: 3)
        XCTAssertEqual(samples.count, 48000)
        XCTAssertLessThan(samples.prefix(30000).map { abs($0) }.max() ?? 1, 0.001)
        let energy = samples.suffix(12000).reduce(Float(0)) { $0 + $1 * $1 } / 12000
        XCTAssertGreaterThan(energy, 0.02)
        XCTAssertThrowsError(try SpeechAudioChunk.read(asset: composition, track: track, start: 0, duration: 26))
    }

    func testBundledMindMapRendersDocumentTextWithoutInterpretingMarkup() async throws {
        var document = NoteDocument(kind: .mindMap, title: "导图")
        let title = "<img src=x> 经济学 English"
        document.nodes[0].title = title
        let host = UIHostingController(rootView: NoteMindMapView(document: document, onEdit: { _, _ in document }, onHistory: { _ in }, onError: { XCTFail($0) }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        host.view.layoutIfNeeded()

        // Literal topic text must surface verbatim through the accessibility
        // tree; a native surface has no HTML parser that could interpret the
        // markup, and no WKWebView may exist anywhere in the hierarchy.
        let labels = await waitForAccessibilityTexts(in: host.view, containing: [title])
        XCTAssertTrue(labels.contains(where: { $0.contains(title) }),
                      "Topic text must render literally; labels: \(labels)")
        XCTAssertFalse(viewHierarchyContainsWebView(host.view), "The native mind map must not embed a WebKit surface")
        let evidence = XCTAttachment(image: snapshot(host.view))
        evidence.name = "Notes mind map component — literal Chinese and English text"
        evidence.lifetime = .keepAlways
        add(evidence)

        // A real image resource must render inside the topic card.
        let imageID = UUID()
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        var illustrated = document; illustrated.revision += 1; illustrated.nodes[0].imageResourceID = imageID
        host.rootView = NoteMindMapView(document: illustrated, onEdit: { _, _ in illustrated }, onHistory: { _ in }, onError: { XCTFail($0) },
                                        images: [imageID: try XCTUnwrap(picture.pngData())])
        host.view.layoutIfNeeded()
        _ = await waitForAccessibilityTexts(in: host.view, containing: [title])
        XCTAssertTrue(viewHierarchyContainsImage(host.view), "A decoded image resource must render in the topic card")
        let illustratedSnapshot = XCTAttachment(image: snapshot(host.view))
        illustratedSnapshot.name = "Notes mind map component — embedded image"
        illustratedSnapshot.lifetime = .keepAlways; add(illustratedSnapshot)

        // Direction updates and long labels must reflow without overlap. The
        // component host proves the view commits no error; the pure layout
        // engine proves the geometry contract the view renders from.
        var expanded = illustrated
        expanded.revision += 1
        expanded.mindMapDirection = 3
        let rootID = expanded.nodes[0].id
        expanded.nodes += (0..<6).map { index in
            MindMapNode(parentID: rootID,
                        title: "分支 \(index) — Opportunity cost and international economics",
                        order: index)
        }
        let expandedMap = expanded
        host.rootView = NoteMindMapView(document: expandedMap, onEdit: { _, _ in expandedMap }, onHistory: { _ in }, onError: { XCTFail($0) },
                                        images: [imageID: try XCTUnwrap(picture.pngData())])
        host.view.layoutIfNeeded()
        _ = await waitForAccessibilityTexts(in: host.view, containing: ["分支 5"])
        let frames = MindMapLayout.frames(document: expandedMap, sizes: [:])
        XCTAssertEqual(frames.count, expandedMap.nodes.count, "Every visible topic needs a frame")
        let rects = expandedMap.nodes.compactMap { frames[$0.id] }.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        for (index, first) in rects.enumerated() {
            for (other, second) in rects.enumerated() where other != index {
                XCTAssertFalse(first.insetBy(dx: -1, dy: -1).intersects(second),
                               "Topics must not overlap after a direction update")
            }
        }
        let rightFrames = MindMapLayout.frames(document: expandedMap, sizes: [:])
        XCTAssertEqual(rightFrames.count, frames.count)
    }

    // MARK: - Native hierarchy probes

    @MainActor
    private func accessibilityTexts(in view: UIView) -> [String] {
        var output: [String] = []
        var stack: [UIView] = [view]
        while let current = stack.popLast() {
            if let label = current.accessibilityLabel, !label.isEmpty { output.append(label) }
            if let value = current.accessibilityValue, !value.isEmpty { output.append(value) }
            stack.append(contentsOf: current.subviews)
        }
        return output
    }

    @MainActor
    private func waitForAccessibilityTexts(in view: UIView, containing needles: [String], timeout: TimeInterval = 15) async -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let labels = accessibilityTexts(in: view)
            if needles.allSatisfy({ needle in labels.contains(where: { $0.contains(needle) }) }) { return labels }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return accessibilityTexts(in: view)
    }

    @MainActor
    private func viewHierarchyContainsWebView(_ view: UIView) -> Bool {
        if NSStringFromClass(type(of: view)).hasPrefix("WKWebView") { return true }
        return view.subviews.contains(where: viewHierarchyContainsWebView)
    }

    @MainActor
    private func viewHierarchyContainsImage(_ view: UIView) -> Bool {
        if let imageView = view as? UIImageView, imageView.image != nil { return true }
        return view.subviews.contains(where: viewHierarchyContainsImage)
    }

    @MainActor
    private func snapshot(_ view: UIView) -> UIImage {
        UIGraphicsImageRenderer(bounds: view.bounds).image { context in
            view.layer.render(in: context.cgContext)
        }
    }

    func testLongBilingualAnswerPaginatesWithoutLosingEditableText() throws {
        let answer = String(repeating: "普通话与 English learning，保留全部解释。\n", count: 400)
        let pages = NotesTextLayout.pages(text: answer, source: nil)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.flatMap(\.elements).map(\.text).joined(), answer)
        XCTAssertTrue(pages.flatMap(\.elements).allSatisfy(\.isAIGenerated))
        for page in pages {
            for element in page.elements {
                let bounds = (element.text as NSString).boundingRect(with: CGSize(width: element.frame.width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: UIFont.systemFont(ofSize: element.fontSize)], context: nil)
                XCTAssertLessThanOrEqual(ceil(bounds.height), element.frame.height)
            }
        }
    }
    func testPDFExportRetainsPagesInkAndText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        var document = NoteDocument(title: "中文课件批注")
        document.pages = [NotePage(width: 400, height: 600, paper: .plain, elements: [
            .init(frame: .init(x: 35, y: 35, width: 320, height: 100), text: "普通话 English 123", fontSize: 26)
        ]), NotePage(width: 600, height: 400, paper: .grid)]
        let points = [CGPoint(x: 30, y: 180), CGPoint(x: 350, y: 180)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index), size: CGSize(width: 12, height: 12), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let ink = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
        let inkURL = root.appendingPathComponent("ink.drawing")
        try ink.dataRepresentation().write(to: inkURL)
        document.pages[0].drawingResourceID = try await store.importResource(from: inkURL, mediaType: "application/vnd.apple.pencilkit")
        document = try await store.create(document)
        var progress: [Int] = []
        let artifact = try await NotesExport.pdf(document: document, store: store) { page, _ in progress.append(page) }
        defer { try? FileManager.default.removeItem(at: artifact.url.deletingLastPathComponent()) }
        let pdf = try XCTUnwrap(CGPDFDocument(artifact.url as CFURL))
        XCTAssertEqual(pdf.numberOfPages, 2)
        XCTAssertEqual(progress, [1, 2])
        XCTAssertEqual(pdf.page(at: 1)?.getBoxRect(.mediaBox).size, CGSize(width: 400, height: 600))
        XCTAssertEqual(pdf.page(at: 2)?.getBoxRect(.mediaBox).size, CGSize(width: 600, height: 400))
        let imported = try await NoteFileImporter.importFile(artifact.url, notebookID: nil, store: store)
        XCTAssertTrue(imported.pages[0].extractedText?.contains("English") == true)
        let savedImport = try await store.create(imported)
        let second = try await NotesExport.pdf(document: savedImport, store: store) { _, _ in }
        defer { try? FileManager.default.removeItem(at: second.url.deletingLastPathComponent()) }
        let reopened = try await NoteFileImporter.importFile(second.url, notebookID: nil, store: store)
        XCTAssertTrue(reopened.pages[0].extractedText?.contains("English") == true, "PDF backgrounds must remain searchable after annotation export")
        let rendered = try await NoteFileImporter.background(page: imported.pages[0], store: store)
        let image = try XCTUnwrap(rendered.flatMap { UIImage(data: $0) })
        let imageAttachment = XCTAttachment(image: image)
        imageAttachment.name = "annotated-pdf-export-page-1"; imageAttachment.lifetime = .keepAlways
        add(imageAttachment)
        // Stroke pixels must survive flattening into a re-readable PDF.
        let crop = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            context.cgContext.translateBy(x: -200, y: -180)
            image.draw(in: CGRect(x: 0, y: 0, width: 400, height: 600))
        }
        let pixels = try XCTUnwrap(crop.cgImage?.dataProvider?.data) as Data
        XCTAssertTrue(pixels.prefix(3).allSatisfy { $0 < 80 })
    }

    func testCorruptInkFailsWithoutReplacingSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let url = root.appendingPathComponent("broken.drawing")
        let bytes = Data("not a PencilKit drawing".utf8)
        try bytes.write(to: url)
        let resource = try await store.importResource(from: url, mediaType: "application/vnd.apple.pencilkit")
        var document = NoteDocument(title: "损坏笔迹")
        document.pages[0].drawingResourceID = resource
        document = try await store.create(document)
        do {
            _ = try await NotesExport.pdf(document: document, store: store) { _, _ in }
            XCTFail("Corrupt ink must not become a successful empty export")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let saved = try await store.document(document.id)
        XCTAssertEqual(saved.pages[0].drawingResourceID, resource)
    }

    func testWhisperManifestIsPinnedAndMultilingual() async throws {
        let manifest = try await WhisperModelStore.shared.manifest()
        XCTAssertEqual(manifest.id, "whisper-small-multilingual")
        XCTAssertEqual(manifest.sourceRevision.count, 40)
        XCTAssertTrue(manifest.files.contains { $0.path == "tokenizer/tokenizer.json" })
        XCTAssertTrue(manifest.files.contains { $0.path == "model/AudioEncoder.mlmodelc/weights/weight.bin" })
        XCTAssertTrue(manifest.files.allSatisfy { $0.sha256.count == 64 && $0.url.path.contains("/resolve/") })
    }
}
