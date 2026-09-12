// SPDX-License-Identifier: MPL-2.0
import XCTest
import AVFoundation
import UIKit
import PencilKit
import SwiftUI
import WebKit
import FloeNotes
@testable import FloeNotesNativeQualification

@MainActor final class NativeNotesTests: XCTestCase {
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
        func find(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap(find).first
        }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let web = find(host.view), let text = try? await web.callAsyncJavaScript("return document.querySelector('me-tpc .text')?.textContent", arguments: [:], in: nil, contentWorld: .page) as? String,
               text == title {
                let images = try await web.callAsyncJavaScript("return document.querySelectorAll('me-tpc img').length", arguments: [:], in: nil, contentWorld: .page) as? Int
                XCTAssertEqual(images, 0)
                let screenshot = try await web.takeSnapshot(configuration: nil)
                let attachment = XCTAttachment(image: screenshot)
                attachment.name = "Notes mind map component — literal Chinese and English text"
                attachment.lifetime = .keepAlways
                add(attachment)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Bundled map did not render the native document")
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
