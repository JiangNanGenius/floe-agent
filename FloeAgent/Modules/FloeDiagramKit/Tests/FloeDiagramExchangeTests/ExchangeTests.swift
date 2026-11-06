// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreGraphics
import ImageIO
import FloeDiagramCore
import FloeDiagramIntegration
@testable import FloeDiagramExchange

@Suite struct ExchangeTests {
    @Test func nativeArchivePreservesEntireDocumentAndResources() async throws {
        let document = DiagramExamples.library(), assets = InMemoryDiagramAssets([DiagramExamples.id(50): DiagramExamples.pixelPNG])
        let output = try await DiagramExchange.export(document, format: .floemap, assets: assets)
        let imported = try DiagramExchange.importData(output.data, format: .floemap)
        #expect(imported.document == document)
        #expect(imported.assets[DiagramExamples.id(50)] == DiagramExamples.pixelPNG)
        var files = try DiagramZIP.unpack(output.data); files["diagram.json"] = Data("changed".utf8)
        do { _ = try DiagramExchange.importData(DiagramZIP.pack(files), format: .floemap); Issue.record("tampered document accepted") } catch {}
        files = try DiagramZIP.unpack(output.data); files.removeValue(forKey: "assets/"+DiagramExamples.id(50).uuidString)
        do { _ = try DiagramExchange.importData(DiagramZIP.pack(files), format: .floemap); Issue.record("missing asset accepted") } catch {}
    }
    @Test func outlineFormatsCarryTreeNotesAndUnicode() throws {
        let a = DiagramElement(title: "Root <中文>"), b = DiagramElement(title: "Child & details")
        var child = b; child.parentID = a.id; child.content = [.note("备注 preserved")]
        let document = DiagramDocument(title: "Outline", pages: [.init(elements: [a, child])])
        for format in [DiagramFormat.freemind, .opml, .markdown] {
            let encoded = try OutlineCodec.encode(document, page: document.pages[0], format: format)
            let imported = try DiagramExchange.importData(encoded.data, format: format)
            #expect(imported.document.pages[0].elements.count == 2)
            #expect(imported.document.pages[0].elements[1].title == child.title)
            #expect(imported.document.pages[0].elements[1].content.map(\.plainText).joined().contains("preserved"))
        }
    }
    @Test func markdownTasksAndCodeHaveEditableRepresentations() throws {
        let data = Data("# 项目\n- [x] 完成\n  - [ ] 继续\n    \u{60}\u{60}\u{60}swift\n    let count = 2\n    \u{60}\u{60}\u{60}\n".utf8)
        let imported = try DiagramExchange.importData(data, format: .markdown)
        #expect(imported.document.tasks.count == 2)
        #expect(imported.document.tasks[0].status == .done)
        #expect(imported.document.pages[0].elements.last!.content.contains { if case .code = $0 { return true }; return false })
    }
    @Test func xmindModernEditableSubsetAndOldXML() async throws {
        var document = DiagramExamples.library()
        document.pages = [document.pages[0]]
        document.pages[0].elements[1].content.append(.image(assetID: DiagramExamples.id(50), caption: "image"))
        let encoded = try await XMindCodec.encode(document, resolver: InMemoryDiagramAssets([DiagramExamples.id(50): DiagramExamples.pixelPNG]))
        let imported = try XMindCodec.decode(encoded.data)
        #expect(imported.document.pages[0].elements.count == document.pages[0].elements.count)
        #expect(imported.document.pages[0].connections.count == 1)
        #expect(imported.assets.count == 1)
        #expect(!encoded.issues.isEmpty)
        let xml = "<xmap-content><sheet id=\"sheet\"><title>旧格式</title><topic id=\"a\"><title>Root</title><children><topics type=\"attached\"><topic id=\"b\"><title>Child</title><notes><plain>note</plain></notes></topic></topics></children></topic></sheet></xmap-content>"
        let old = try XMindCodec.decode(DiagramZIP.pack(["content.xml": Data(xml.utf8)]))
        #expect(old.document.pages[0].elements.count == 2)
        #expect(old.document.pages[0].elements[1].parentID == old.document.pages[0].elements[0].id)
    }
    @Test func drawioCompressedAndUncompressedSwimlaneFiles() throws {
        let document = DiagramDocument(title: "流程", pages: [DiagramExamples.library().pages[1]], tasks: DiagramExamples.library().tasks)
        for compressed in [false, true] {
            let encoded = try DrawIOCodec.encode(document, compressed: compressed)
            let imported = try DrawIOCodec.decode(encoded.data, title: "流程")
            #expect(imported.document.pages[0].elements.count == document.pages[0].elements.count)
            #expect(imported.document.pages[0].connections.count == document.pages[0].connections.count)
            #expect(imported.document.pages[0].elements.contains { $0.kind == .swimlane })
            let first = imported.document.element(DiagramExamples.id(510))
            #expect(first?.frame == document.element(DiagramExamples.id(510))?.frame)
        }
    }
    @Test func drawioEdgesAcceptLoopsAndRejectMissingCoordinates() throws {
        let xml = "<mxGraphModel><root><mxCell id=\"0\"/><mxCell id=\"1\" parent=\"0\"/><mxCell id=\"a\" value=\"A\" vertex=\"1\" parent=\"1\"><mxGeometry x=\"0\" y=\"0\" width=\"100\" height=\"60\"/></mxCell><mxCell id=\"e\" edge=\"1\" source=\"a\" target=\"a\" parent=\"1\"><mxGeometry relative=\"1\"/></mxCell></root></mxGraphModel>"
        let imported = try DrawIOCodec.decode(Data(xml.utf8), title: "Loop")
        try imported.document.validate(); #expect(imported.document.pages[0].connections[0].from == imported.document.pages[0].connections[0].to)
        do { _ = try DrawIOCodec.decode(Data(xml.replacingOccurrences(of: "target=\"a\"", with: "").utf8), title: "Bad"); Issue.record("dangling connector accepted") } catch {}
    }
    @Test func mermaidFlowMindmapGantt() throws {
        let flow = "flowchart TD\nA[\"开始 中文\"] -->|确认| B{Ready?}\nB -.-> A\n"
        let graph = try MermaidCodec.decode(Data(flow.utf8), title: "Flow")
        #expect(graph.document.pages[0].elements.count == 2)
        #expect(graph.document.pages[0].connections.count == 2)
        let map = try MermaidCodec.decode(Data("mindmap\n  root((项目))\n    a[\"设计\"]\n      b[\"评审\"]".utf8), title: "Map")
        #expect(map.document.pages[0].elements[2].parentID == map.document.pages[0].elements[1].id)
        let gantt = try MermaidCodec.decode(Data("gantt\n dateFormat YYYY-MM-DD\n A :a, 2026-11-02, 3d\n B :active, b, after a, 2d".utf8), title: "Gantt")
        #expect(gantt.document.tasks.count == 2 && gantt.document.dependencies.count == 1)
        #expect(gantt.document.tasks[1].start! > gantt.document.tasks[0].end!)
        let encoded = try MermaidCodec.encodeGantt(gantt.document)
        let again = try MermaidCodec.decode(encoded.data, title: "Gantt")
        #expect(again.document.tasks.count == 2 && again.document.dependencies.count == 1)
    }
    @Test func XMLDeclarationsAndInvalidArchivesFailClosed() throws {
        do { _ = try DiagramXML.parse(Data("<!DOCTYPE x [<!ENTITY a SYSTEM 'file:///etc/passwd'>]><map>&a;</map>".utf8)); Issue.record("entity declaration accepted") } catch {}
        do { _ = try DiagramZIP.pack(["../escape": Data("x".utf8)]); Issue.record("unsafe archive path accepted") } catch {}
        do { _ = try DiagramRawDeflate.decode(Data("garbage".utf8)); Issue.record("invalid compressed stream accepted") } catch {}
    }
}
@Suite @MainActor struct NativeExportTests {
    @Test func formulaAndRasterVectorOutputsAreReal() async throws {
        let renderer = DiagramNativeRenderer()
        #expect(renderer.formulaIsValid("\\frac{a}{b} + x^2"))
        #expect(!renderer.formulaIsValid("\\frac{"))
        let document = DiagramExamples.library(), assets = InMemoryDiagramAssets([DiagramExamples.id(50): DiagramExamples.pixelPNG])
        let pdf = try await DiagramExchange.export(document, format: .pdf, assets: assets)
        #expect(pdf.data.starts(with: Data("%PDF-".utf8)))
        let pdfDocument = CGPDFDocument(CGDataProvider(data: pdf.data as CFData)!)!
        #expect(pdfDocument.numberOfPages == 3)
        let png = try await DiagramExchange.export(document, format: .png, pageID: document.pages[0].id, assets: assets)
        let source = CGImageSourceCreateWithData(png.data as CFData, nil)
        #expect(source != nil && CGImageSourceGetCount(source!) == 1)
        let svg = try await DiagramExchange.export(document, format: .svg, pageID: document.pages[0].id, assets: assets)
        let xml = try DiagramXML.parse(svg.data)
        #expect(xml.name == "svg" && !xml.descendants("path").isEmpty)
        #expect(svg.issues.contains { $0.code == "formulaRasterized" })
        let plan = try DiagramPlanProjection.document(document)
        let planPDF = try await DiagramExchange.export(plan, format: .pdf, assets: assets)
        #expect(planPDF.data.starts(with: Data("%PDF-".utf8)))
    }
}
