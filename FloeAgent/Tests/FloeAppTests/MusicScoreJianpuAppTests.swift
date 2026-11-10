// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CryptoKit
import XCTest
import SwiftUI
import UIKit
import WebKit
import FloeHeavyEditorSupport
import FloeScoreKit
import FloeMusicCore
@testable import FloeApp

/// Runs against the bundled iOS editor and the existing Music-owned original.
/// No separate JS engine, readiness override, audio start or provider call.
@MainActor final class MusicScoreJianpuAppTests: XCTestCase {
    func testNumberedProjectionEditsSameOriginalReopensAndExportsGraphics() async throws {
        let environment = FloeAgentApp.liveEnvironment
        let record = try await PersonalContentService.shared.create(kind: .music,
            title: "QA-Jianpu-" + UUID().uuidString)
        let location = try await PersonalContentService.shared.library().resolve(record.id)
        let musicRoot = location.url.appendingPathComponent("Music")
        let session = try await MusicProjectSession.open(id: record.id, directory: musicRoot, environment: environment)
        let arrangement = session.document
        var hosts: [JianpuHost] = []
        defer { for host in hosts { host.close() } }
        let owned = XCTAttachment(string: "Owned Jianpu fixture: \(record.id.uuidString)\n\(location.url.path)\nRetain for Root UI readback, then remove only this ID through the normal library action.")
        owned.name = "Owned numbered-score original"; owned.lifetime = .keepAlways; add(owned)

        let first = try await mount(session)
        hosts.append(first)
        let controller = first.controller
        let notation = try XCTUnwrap(session.notation)
        _ = try await controller.execute("file.import", arguments: .object([
            "name": .string("Jianpu-original.musicxml"),
            "base64": .string(Data(Self.musicXML.utf8).base64EncodedString())]))
        let originalXML = try sourceXML(controller.document)
        let performance = try await controller.execute("score.playback.compile")
        _ = try await controller.execute("score.view.notation", arguments: .object(["notation": .string("jianpu")]))
        XCTAssertEqual(try sourceXML(controller.document), originalXML)
        XCTAssertEqual(controller.presentation["view"]["notation"].string, "jianpu")
        let numberedPerformance = try await controller.execute("score.playback.compile")
        XCTAssertEqual(numberedPerformance["result"]["events"], performance["result"]["events"])

        let rendered = try await pageJSON(controller, """
            const e=window.FloeEditor, s=e.scoreSurface;
            return JSON.stringify({pages:s.querySelectorAll('svg[data-score-notation="jianpu"]').length,
              notes:e.noteVisuals.size,first:e.noteVisuals.get('p1-g')?.querySelector('.jp-number')?.textContent,
              leading:e.noteVisuals.get('p1-fs')?.querySelector('.jp-number')?.textContent,
              rest:e.noteVisuals.get('p1-rest')?.querySelector('.jp-number')?.textContent,
              lyrics:s.querySelectorAll('[data-jianpu-lyric]').length,
              ties:s.querySelectorAll('[data-jianpu-tie]').length,
              instruments:[...s.querySelectorAll('[data-jianpu-part]')].map(n=>n.dataset.jianpuPart),
              keys:['1=G','1=D♭','6=A'].every(k=>s.textContent.includes(k))});
            """)
        XCTAssertGreaterThan(rendered["pages"].number ?? 0, 0)
        XCTAssertEqual(rendered["notes"].number, 19)
        XCTAssertEqual(rendered["first"].string, "1")
        XCTAssertEqual(rendered["leading"].string, "7")
        XCTAssertEqual(rendered["rest"].string, "0")
        XCTAssertEqual(rendered["lyrics"].number, 2)
        XCTAssertGreaterThan(rendered["ties"].number ?? 0, 0)
        XCTAssertEqual(Set(rendered["instruments"].array.compactMap(\.string)), Set(["P1", "P2"]))
        XCTAssertEqual(rendered["keys"], .bool(true))

        // These are the production pointer handlers and the native command FIFO.
        // Poll only for their result; do not replace the selection implementation.
        let selected = try await pageJSON(controller, """
            const e=window.FloeEditor, target=e.noteVisuals.get('p1-fs');
            if(!target)throw new Error('No numbered note hit target');
            const r=target.getBoundingClientRect(), event={bubbles:true,pointerId:71,
              clientX:r.x+r.width/2,clientY:r.y+r.height/2};
            target.dispatchEvent(new PointerEvent('pointerdown',event));
            target.dispatchEvent(new PointerEvent('pointerup',event));
            for(let i=0;i<100;i++){
              if(e.selection?.note==='p1-fs')return JSON.stringify({note:e.selection.note});
              await new Promise(r=>setTimeout(r,30));
            }
            throw new Error('Numbered note pointer did not select the original ID');
            """)
        XCTAssertEqual(selected["note"].string, "p1-fs")
        _ = try await controller.execute("score.edit.update", arguments: .object(["pitch": .string("F5")]))
        let edited = try await pageJSON(controller, """
            const e=window.FloeEditor;
            return JSON.stringify({note:e.selection.note,
              accidental:e.noteVisuals.get('p1-fs')?.querySelector('.jp-accidental')?.textContent});
            """)
        XCTAssertEqual(edited["note"].string, "p1-fs")
        XCTAssertEqual(edited["accidental"].string, "♭")
        XCTAssertNotEqual(try sourceXML(controller.document), originalXML)
        _ = try await controller.execute("history.undo")
        XCTAssertEqual(try sourceXML(controller.document), originalXML)
        XCTAssertEqual(controller.presentation["view"]["notation"].string, "jianpu")
        XCTAssertEqual(controller.presentation["numberedInput"]["keys"].array.first?["pitch"].string, "G4")

        let beforeExport = controller.document
        let beforeSelection = controller.presentation["selection"]
        var exportEvidence: [String] = []
        for format in ["svg", "png", "pdf"] {
            let response = try await controller.execute("score.export", arguments: .object([
                "format": .string(format), "scale": .number(1)]))
            let artifacts = response["artifacts"].array
            let receipts = response["exports"].array
            XCTAssertFalse(artifacts.isEmpty, "Original offline exporter returned no \(format) bytes")
            XCTAssertEqual(receipts.count, artifacts.count)
            for (index, receipt) in receipts.enumerated() {
                let fileID = try XCTUnwrap(receipt["fileID"].string)
                let file = try notation.exportURL(fileID: fileID)
                let data = try Data(contentsOf: file)
                let returnedBytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(artifacts[index]["base64"].string)))
                XCTAssertEqual(data, returnedBytes)
                XCTAssertEqual(data.count, Int(receipt["byteCount"].number ?? -1))
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(digest, receipt["sha256"].string)
                switch format {
                case "svg":
                    let svg = String(decoding: data, as: UTF8.self)
                    XCTAssertTrue(svg.contains("data-score-notation=\"jianpu\""))
                    XCTAssertTrue(svg.contains("jp-number"))
                    XCTAssertTrue(svg.contains("晨光"))
                case "png":
                    let image = try XCTUnwrap(UIImage(data: data)?.cgImage, "PNG must decode with the native image stack")
                    XCTAssertGreaterThanOrEqual(image.width, 640)
                    XCTAssertGreaterThan(darkPixels { $0.draw(image, in: Self.sampleRect) }, 30,
                        "A decodable white PNG is not a rendered numbered score")
                case "pdf":
                    let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
                    let pdf = try XCTUnwrap(CGPDFDocument(provider), "PDF must parse with Core Graphics")
                    XCTAssertGreaterThan(pdf.numberOfPages, 0)
                    let page = try XCTUnwrap(pdf.page(at: 1))
                    XCTAssertGreaterThan(darkPixels { context in
                        context.concatenate(page.getDrawingTransform(.mediaBox, rect: Self.sampleRect,
                            rotate: 0, preserveAspectRatio: true))
                        context.drawPDFPage(page)
                    }, 30, "The PDF page must contain actual numbered engraving")
                default: XCTFail("Unexpected fixture format")
                }
                if index == 0 {
                    let attachment = XCTAttachment(data: data, uniformTypeIdentifier:
                        format == "svg" ? "public.svg-image" : format == "png" ? "public.png" : "com.adobe.pdf")
                    attachment.name = "Original offline Jianpu export.\(format)"
                    attachment.lifetime = .keepAlways; add(attachment)
                }
                exportEvidence.append("\(format) \(file.lastPathComponent) \(data.count) bytes sha256=\(digest)")
            }
            XCTAssertEqual(controller.document, beforeExport, "Graphic export must not mutate the original or revision")
            XCTAssertEqual(controller.presentation["selection"], beforeSelection)
        }
        let screen = try await controller.webView.takeSnapshot(configuration: nil)
        let screenAttachment = XCTAttachment(image: screen)
        screenAttachment.name = "Actual iOS WK numbered engraving"; screenAttachment.lifetime = .keepAlways; add(screenAttachment)
        try await controller.save()
        let saved = try XCTUnwrap(MusicNotationPackage.readOriginal(root: session.root, parentID: record.id))
        XCTAssertEqual(saved.binding.musicProjectID, record.id)
        XCTAssertEqual(saved.document, controller.document)
        XCTAssertEqual(try sourceXML(saved.document), originalXML)
        // Closing a presentation intentionally keeps the process-owned Music
        // parent and its notation service. Reopening the same library original
        // through MusicProjectSession.open is a warm reuse, not a cold disk read.
        await controller.endPresentation()
        first.close()
        hosts.removeAll()
        let reopened = try await MusicProjectSession.open(id: record.id, directory: musicRoot, environment: environment)
        XCTAssertTrue(reopened === session, "Normal view close must retain the Music-owned parent")
        XCTAssertTrue(reopened.notation?.controller === controller, "Warm reopen must retain this original's notation service")

        // The product has no parent-cache eviction on view close. Explicitly
        // retire only this test-owned idle child via the existing host teardown
        // fence, then release its cached link. Keep the retired controller solely
        // as an identity comparator; no stale view/operation can own the new child.
        notation.invalidateForRestore()
        XCTAssertNil(notation.controller)
        reopened.notation = nil
        let disk = try HeavyEditorProjectStore(directory: MusicNotationPackage.notationRoot(musicRoot),
            documentID: record.id, kind: .score)
        let diskDocument = try await disk.read()
        XCTAssertEqual(diskDocument, saved.document, "Fresh store must read the actual committed original")
        let second = try await mount(reopened)
        hosts.append(second)
        XCTAssertFalse(reopened.notation === notation, "The retired notation service must not be adopted")
        XCTAssertFalse(second.controller === controller)
        XCTAssertEqual(second.controller.document, saved.document)
        XCTAssertEqual(second.controller.presentation["view"]["notation"].string, "jianpu")
        let reopenedPage = try await pageJSON(second.controller, """
            const e=window.FloeEditor;
            return JSON.stringify({pages:e.scoreSurface.querySelectorAll('[data-score-notation="jianpu"]').length,
              ids:[...e.noteVisuals.keys()].sort(),xml:e.state.xml});
            """)
        XCTAssertGreaterThan(reopenedPage["pages"].number ?? 0, 0)
        XCTAssertEqual(reopenedPage["ids"].array.compactMap(\.string), Self.noteIDs.sorted())
        XCTAssertEqual(reopenedPage["xml"].string, originalXML)
        _ = try await second.controller.execute("score.view.notation", arguments: .object(["notation": .string("staff")]))
        XCTAssertEqual(try sourceXML(second.controller.document), originalXML)
        let staff = try await pageJSON(second.controller, """
            const e=window.FloeEditor;
            return JSON.stringify({staffPaths:e.scoreSurface.querySelectorAll('svg path').length,
              numbered:e.scoreSurface.querySelectorAll('[data-score-notation="jianpu"]').length});
            """)
        XCTAssertGreaterThan(staff["staffPaths"].number ?? 0, 0)
        XCTAssertEqual(staff["numbered"].number, 0)
        _ = try await second.controller.execute("history.undo")
        XCTAssertEqual(second.controller.presentation["view"]["notation"].string, "jianpu")
        XCTAssertEqual(try sourceXML(second.controller.document), originalXML)
        XCTAssertEqual(session.document, arrangement)
        let storedArrangement = try await session.repository.load(projectID: arrangement.id)
        XCTAssertEqual(storedArrangement, arrangement, "Notation must not overwrite the arrangement original")
        let evidence = XCTAttachment(string: "Bundled iOS WK; source note IDs=19; original XML unchanged by view/undo/export/reopen.\n" + exportEvidence.joined(separator: "\n"))
        evidence.name = "Numbered original and offline export readback"; evidence.lifetime = .keepAlways; add(evidence)
        await second.controller.endPresentation()
    }

    private func sourceXML(_ document: HeavyEditorDocument) throws -> String {
        try XCTUnwrap(document.content["data"]["xml"].string ?? document.content["xml"].string)
    }
    private func pageJSON(_ controller: HeavyEditorController, _ body: String) async throws -> EditorJSON {
        let result = try await controller.webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
        return try EditorJSON.decode(Data(try XCTUnwrap(result as? String).utf8))
    }
    @MainActor private struct JianpuHost {
        let window: UIWindow
        let controller: HeavyEditorController
        func close() {
            controller.cancel()
            window.isHidden = true
            window.rootViewController = nil
        }
    }
    private func mount(_ session: MusicProjectSession) async throws -> JianpuHost {
        let host = UIHostingController(rootView: MusicNotationWorkbench(session: session, onAssistant: {}, onClose: {}))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: -2_000, y: 0, width: 1_120, height: 900))
        window.frame = CGRect(x: -2_000, y: 0, width: 1_120, height: 900)
        window.rootViewController = host; window.isHidden = false
        host.view.frame = window.bounds; host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        var retained = false
        defer { if !retained { session.notation?.controller?.cancel(); window.isHidden = true; window.rootViewController = nil } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while session.notation?.controller == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        }
        let controller = try XCTUnwrap(session.notation?.controller, "Production workbench did not publish its controller")
        while (controller.webView.window !== window || controller.webView.bounds.width <= 0 || controller.webView.bounds.height <= 0), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        }
        XCTAssertTrue(controller.webView.window === window)
        XCTAssertGreaterThan(controller.webView.bounds.width, 0)
        XCTAssertGreaterThan(controller.webView.bounds.height, 0)
        try await controller.waitUntilReady()
        XCTAssertTrue(controller.isReady)
        retained = true
        return JianpuHost(window: window, controller: controller)
    }

    private static let sampleRect = CGRect(x: 0, y: 0, width: 256, height: 256)
    private func darkPixels(_ draw: (CGContext) -> Void) -> Int {
        var pixels = [UInt8](repeating: 255, count: 256 * 256 * 4)
        return pixels.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: 256, height: 256,
                bitsPerComponent: 8, bytesPerRow: 256 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
            context.setFillColor(UIColor.white.cgColor); context.fill(Self.sampleRect)
            draw(context)
            let bytes = storage.bindMemory(to: UInt8.self)
            return stride(from: 0, to: bytes.count, by: 4).reduce(0) { result, offset in
                result + (Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2]) < 660 ? 1 : 0)
            }
        }
    }
    private static let noteIDs = ["p1-g", "p1-a", "p1-b", "p1-fs", "p1-low", "p1-rest", "p1-db", "p1-f", "p1-ab", "p1-16", "p1-dot", "p1-end", "p1-rest2", "p2-a", "p2-a2", "p2-b", "p2-c", "p2-rest", "p2-low"]
    private static let musicXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <score-partwise version="4.0">
      <work><work-title>晨光 · 简谱与五线谱</work-title></work>
      <identification><creator type="composer">Floe 原创测试</creator></identification>
      <part-list>
        <score-part id="P1"><part-name>钢琴</part-name><score-instrument id="I1"><instrument-name>Piano</instrument-name></score-instrument><midi-instrument id="I1"><midi-channel>1</midi-channel><midi-program>1</midi-program></midi-instrument></score-part>
        <score-part id="P2"><part-name>长笛</part-name><score-instrument id="I2"><instrument-name>Flute</instrument-name></score-instrument><midi-instrument id="I2"><midi-channel>2</midi-channel><midi-program>74</midi-program></midi-instrument></score-part>
      </part-list>
      <part id="P1">
        <measure number="1"><attributes><divisions>960</divisions><key><fifths>1</fifths><mode>major</mode></key><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>
          <note id="p1-g"><pitch><step>G</step><octave>4</octave></pitch><duration>960</duration><voice>1</voice><type>quarter</type><lyric><text>晨</text></lyric></note>
          <note id="p1-a"><pitch><step>A</step><octave>4</octave></pitch><duration>480</duration><voice>1</voice><type>eighth</type><lyric><text>光</text></lyric></note>
          <note id="p1-b"><pitch><step>B</step><octave>4</octave></pitch><duration>480</duration><voice>1</voice><type>eighth</type></note>
          <note id="p1-fs"><pitch><step>F</step><alter>1</alter><octave>5</octave></pitch><duration>1920</duration><voice>1</voice><type>half</type></note>
          <backup><duration>3840</duration></backup>
          <note id="p1-low"><pitch><step>C</step><octave>3</octave></pitch><duration>1920</duration><voice>2</voice><type>half</type></note>
          <note id="p1-rest"><rest/><duration>1920</duration><voice>2</voice><type>half</type></note>
        </measure>
        <measure number="2"><attributes><key><fifths>-5</fifths><mode>major</mode></key></attributes>
          <note id="p1-db"><pitch><step>D</step><alter>-1</alter><octave>4</octave></pitch><duration>960</duration><voice>1</voice><type>quarter</type></note>
          <note id="p1-f"><chord/><pitch><step>F</step><octave>4</octave></pitch><duration>960</duration><voice>1</voice><type>quarter</type></note>
          <note id="p1-ab"><chord/><pitch><step>A</step><alter>-1</alter><octave>4</octave></pitch><duration>960</duration><voice>1</voice><type>quarter</type></note>
          <note id="p1-16"><pitch><step>E</step><alter>-1</alter><octave>4</octave></pitch><duration>240</duration><voice>1</voice><type>16th</type></note>
          <note id="p1-dot"><pitch><step>F</step><octave>4</octave></pitch><duration>720</duration><voice>1</voice><type>eighth</type><dot/></note>
          <note id="p1-end"><pitch><step>D</step><alter>-1</alter><octave>5</octave></pitch><duration>1920</duration><voice>1</voice><type>half</type></note>
          <backup><duration>3840</duration></backup><note id="p1-rest2"><rest/><duration>3840</duration><voice>2</voice><type>whole</type></note>
          <barline location="right"><bar-style>light-heavy</bar-style></barline>
        </measure>
      </part>
      <part id="P2">
        <measure number="1"><attributes><divisions>960</divisions><key><fifths>0</fifths><mode>minor</mode></key><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>
          <note id="p2-a"><pitch><step>A</step><octave>4</octave></pitch><duration>2880</duration><tie type="start"/><voice>1</voice><type>half</type><dot/><notations><tied type="start"/></notations></note>
          <note id="p2-a2"><pitch><step>A</step><octave>4</octave></pitch><duration>960</duration><tie type="stop"/><voice>1</voice><type>quarter</type><notations><tied type="stop"/></notations></note>
        </measure>
        <measure number="2">
          <note id="p2-b"><pitch><step>B</step><octave>4</octave></pitch><duration>480</duration><voice>1</voice><type>eighth</type></note>
          <note id="p2-c"><pitch><step>C</step><octave>5</octave></pitch><duration>480</duration><voice>1</voice><type>eighth</type></note>
          <note id="p2-rest"><rest/><duration>960</duration><voice>1</voice><type>quarter</type></note>
          <note id="p2-low"><pitch><step>C</step><octave>4</octave></pitch><duration>1920</duration><voice>1</voice><type>half</type></note>
          <barline location="right"><bar-style>light-heavy</bar-style></barline>
        </measure>
      </part>
    </score-partwise>
    """
}
#endif
