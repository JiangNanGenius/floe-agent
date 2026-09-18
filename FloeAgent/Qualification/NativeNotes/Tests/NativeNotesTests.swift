// SPDX-License-Identifier: MPL-2.0
import XCTest
import AVFoundation
import UIKit
import PencilKit
import SwiftUI
import WebKit
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
        func find(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap(find).first
        }
        var rendered = false
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let web = find(host.view), let text = try? await web.callAsyncJavaScript("return document.querySelector('#map')?.textContent", arguments: [:], in: nil, contentWorld: .page) as? String,
               text.contains("Trade gains") && text.contains("机会成本") {
                rendered = true; break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(rendered, "The independently stored map must render inside the PDF reader window")
        // Screen capture lives in NativeNotesUITests, which has XCTest UI authorization.
        if let web = find(host.view) {
            let content = XCTAttachment(image: try await web.takeSnapshot(configuration: nil))
            content.name = "Notes linked map — WebKit content evidence"
            content.lifetime = .keepAlways; add(content)
        }
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
        func find(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap(find).first
        }
        // Bounded wait for the committed file document. A cold component host
        // can still be committing its bundled file URL when polling starts, so
        // this waits on a real state predicate (not a fixed delay) before the
        // first DOM read.
        let loadDeadline = Date().addingTimeInterval(30)
        while Date() < loadDeadline {
            if let web = find(host.view), !web.isLoading, web.url?.isFileURL == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        // Every DOM read is individually bounded: `callAsyncJavaScript` can
        // suspend forever if the web process never calls back, and an unbounded
        // await would stall the test for minutes. A `nil` result means the probe
        // timed out or the script threw, and is reported as a failed assertion,
        // never as a fabricated success.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let web = find(host.view),
               let text = await boundedString(web, "return document.querySelector('me-tpc .text')?.textContent"),
               text == title {
                let images = await boundedInt(web, "return document.querySelectorAll('me-tpc img').length")
                XCTAssertEqual(images, 0)
                let screenshot = try await web.takeSnapshot(configuration: nil)
                let attachment = XCTAttachment(image: screenshot)
                attachment.name = "Notes mind map component — literal Chinese and English text"
                attachment.lifetime = .keepAlways
                add(attachment)
                let imageID = UUID()
                let picture = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).image { context in
                    UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
                }
                var updated = document; updated.revision += 1; updated.nodes[0].imageResourceID = imageID
                let illustrated = updated
                host.rootView = NoteMindMapView(document: illustrated, onEdit: { _, _ in illustrated }, onHistory: { _ in }, onError: { XCTFail($0) },
                                               images: [imageID: try XCTUnwrap(picture.pngData())])
                let imageDeadline = Date().addingTimeInterval(10)
                var imageLoaded = false
                while Date() < imageDeadline {
                    imageLoaded = await boundedBool(web, "return Array.from(document.querySelectorAll('me-tpc img')).some(img => img.src.startsWith('data:image/png;') && img.naturalWidth === expectedWidth && img.naturalHeight === expectedHeight)", arguments: ["expectedWidth": picture.cgImage!.width, "expectedHeight": picture.cgImage!.height]) == true
                    if imageLoaded { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                XCTAssertTrue(imageLoaded, "Native image resource did not render in the topic")
                let illustratedSnapshot = XCTAttachment(image: try await web.takeSnapshot(configuration: nil))
                illustratedSnapshot.name = "Notes mind map component — embedded image"
                illustratedSnapshot.lifetime = .keepAlways; add(illustratedSnapshot)
                // Exercise actual WebKit layout, not the mocked bridge: long labels and
                // images must reserve space, and an Agent direction update must reflow.
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
                let layoutDeadline = Date().addingTimeInterval(10)
                var arranged = false
                while Date() < layoutDeadline {
                    arranged = await boundedBool(web, """
                        const tree = document.querySelector('me-root')?.parentElement;
                        const topics = Array.from(document.querySelectorAll('me-tpc'));
                        if (!tree?.classList.contains('down') || topics.length !== 7) return false;
                        const boxes = topics.map(node => node.getBoundingClientRect());
                        return boxes.every((a, i) => a.width > 0 && a.height > 0 &&
                          boxes.every((b, j) => i === j || a.right <= b.left + 1 ||
                            b.right <= a.left + 1 || a.bottom <= b.top + 1 || b.bottom <= a.top + 1));
                        """) == true
                    if arranged { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                XCTAssertTrue(arranged, "Updated image and long-label topics must reflow without overlap")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        // The root cause of a cold first-instance stall is not assumed here:
        // capture the committed URL, loading state, bundle resource and bridge
        // state so the cloud run can distinguish a packaging fault from a slow
        // web process instead of the test masking it with a longer delay.
        let diagnostics = await mindMapDiagnostics(find(host.view))
        let diagnosticAttachment = XCTAttachment(string: diagnostics)
        diagnosticAttachment.name = "Notes mind map failure diagnostics"
        diagnosticAttachment.lifetime = .keepAlways
        add(diagnosticAttachment)
        XCTFail("Bundled map did not render the native document")
    }

    /// Outcome of one bounded DOM probe. `WKWebView.callAsyncJavaScript` can
    /// suspend forever if the web process never invokes its completion handler,
    /// so each probe is raced against a deadline through a single-resume gate;
    /// a late callback after the deadline or a cancellation is a safe no-op.
    @MainActor
    private final class BoundedProbe<Value: Sendable> {
        private var continuation: CheckedContinuation<Value?, Never>?
        private var finished = false
        var timeoutTask: Task<Void, Never>?

        func attach(_ continuation: CheckedContinuation<Value?, Never>) -> Bool {
            guard !finished else {
                continuation.resume(returning: nil)
                return false
            }
            self.continuation = continuation
            return true
        }

        func settle(_ value: Value?) {
            guard !finished else { return }
            finished = true
            timeoutTask?.cancel(); timeoutTask = nil
            let continuation = continuation
            self.continuation = nil
            continuation?.resume(returning: value)
        }
    }

    @MainActor
    private func boundedJS<Value: Sendable>(
        _ web: WKWebView,
        _ script: String,
        arguments: [String: Any] = [:],
        timeout: Duration = .seconds(5),
        convert: @escaping @MainActor @Sendable (Any?) -> Value?
    ) async -> Value? {
        let probe = BoundedProbe<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                guard probe.attach(continuation) else { return }
                web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
                    switch result {
                    case .success(let value): probe.settle(convert(value))
                    case .failure: probe.settle(nil)
                    }
                }
                probe.timeoutTask = Task { @MainActor in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    probe.settle(nil)
                }
            }
        } onCancel: {
            Task { @MainActor in probe.settle(nil) }
        }
    }

    @MainActor
    private func boundedString(_ web: WKWebView, _ script: String, timeout: Duration = .seconds(5)) async -> String? {
        await boundedJS(web, script, timeout: timeout) { $0 as? String }
    }

    @MainActor
    private func boundedInt(_ web: WKWebView, _ script: String, timeout: Duration = .seconds(5)) async -> Int? {
        await boundedJS(web, script, timeout: timeout) { ($0 as? NSNumber)?.intValue ?? ($0 as? Int) }
    }

    @MainActor
    private func boundedBool(_ web: WKWebView, _ script: String, arguments: [String: Any] = [:], timeout: Duration = .seconds(5)) async -> Bool? {
        await boundedJS(web, script, arguments: arguments, timeout: timeout) { ($0 as? NSNumber)?.boolValue ?? ($0 as? Bool) }
    }

    /// Natively-readable failure context plus bounded JS probes. Every probe is
    /// itself bounded, so diagnostics can never hang the test they explain.
    @MainActor
    private func mindMapDiagnostics(_ web: WKWebView?) async -> String {
        var lines: [String] = []
        if let root = Bundle.main.url(forResource: "MindElixir", withExtension: nil) {
            let index = root.appendingPathComponent("index.html")
            lines.append("MindElixir bundle: \(root.path)")
            lines.append("index.html exists: \(FileManager.default.fileExists(atPath: index.path))")
        } else {
            lines.append("MindElixir bundle: MISSING from Bundle.main")
        }
        guard let web else {
            lines.append("WKWebView: not found in host hierarchy")
            return lines.joined(separator: "\n")
        }
        lines.append("url: \(web.url?.absoluteString ?? "nil")")
        lines.append("isLoading: \(web.isLoading)")
        lines.append("estimatedProgress: \(web.estimatedProgress)")
        lines.append("title: \(web.title ?? "nil")")
        lines.append("readyState: \(await boundedString(web, "return document.readyState", timeout: .seconds(3)) ?? "<no reply>")")
        lines.append("typeof floeRender: \(await boundedString(web, "return typeof window.floeRender", timeout: .seconds(3)) ?? "<no reply>")")
        lines.append("me-tpc count: \(await boundedInt(web, "return document.querySelectorAll('me-tpc').length", timeout: .seconds(3)) ?? -1)")
        lines.append("body[0..300]: \(await boundedString(web, "return document.body ? document.body.innerHTML.slice(0, 300) : null", timeout: .seconds(3)) ?? "<no reply>")")
        return lines.joined(separator: "\n")
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
