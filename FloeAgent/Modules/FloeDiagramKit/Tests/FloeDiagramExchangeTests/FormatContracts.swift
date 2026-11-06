import Foundation
import Testing
import CoreGraphics
import PencilKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import FloeDiagramCore
import FloeDiagramIntegration
@testable import FloeDiagramExchange
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@Test func existingNotesArchiveRootAndResourceConvertWithoutFlattening() throws {
    let documentID = UUID(), nodeID = UUID(), imageID = UUID(), png = DiagramExamples.pixelPNG, hash = DiagramCodec.digest(png)
    let document: [String: Any] = ["schemaVersion": 2,"kind": "mindMap","id": documentID.uuidString,"title": "Archived","nodes": [["id": nodeID.uuidString,"title": "Image topic","imageResourceID": imageID.uuidString]],"connections": []]
    // Schema is the existing FloeNotes.NotesArchive v2 Manifest/Resource contract.
    let manifest: [String: Any] = ["version": 2,"document": document,"resources": [["id": imageID.uuidString,"hash": hash,"size": png.count]]]
    let archive = try DiagramZIP.pack(["manifest.json": JSONSerialization.data(withJSONObject: manifest),"resources/"+hash: png])
    let result = try DiagramExchange.importLegacyNotesArchive(archive)
    #expect(result.document.id == documentID && result.document.element(nodeID)?.content.first?.assetID == imageID)
    #expect(result.assets[imageID] == png && result.document.legacyPayload != nil)
}
@Test func freeMindMultiRootHasOneLegalRootAndAnExplicitConversionNotice() throws {
    let document = DiagramDocument(title: "Multiple",pages: [.init(elements: [.init(title: "First"),.init(title: "Second")])])
    let result = try OutlineCodec.encode(document,page: document.pages[0],format: .freemind), xml = try DiagramXML.parse(result.data)
    #expect(xml.children.filter { $0.name == "node" }.count == 1)
    #expect(result.issues.contains { $0.code == "syntheticRoot" })
    #expect(try DiagramExchange.importData(result.data,format: .freemind).document.pages[0].elements.count == 3)
}
@Test func drawIOExportRetainsFoldedDescendantsAndDoesNotDuplicateTreeEdges() throws {
    let root = DiagramElement(title: "Root",collapsed: true), child = DiagramElement(title: "Hidden",parentID: root.id)
    let document = DiagramDocument(pages: [.init(elements: [root,child])])
    let output = try DrawIOCodec.encode(document), returned = try DrawIOCodec.decode(output.data,title: "Returned").document
    #expect(returned.pages[0].elements.count == 2)
    let a = returned.pages[0].elements.first { $0.title == "Root" }!, b = returned.pages[0].elements.first { $0.title == "Hidden" }!
    #expect(a.collapsed && b.parentID == a.id && returned.pages[0].connections.isEmpty)
}
@Test func ganttCalendarDaysRemainCorrectAcrossDaylightSaving() throws {
    let zone = TimeZone(identifier: "America/New_York")!
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
    let start = calendar.date(from: .init(year: 2026,month: 3,day: 7))!, end = calendar.date(from: .init(year: 2026,month: 3,day: 10))!
    let task = DiagramTask(title: "Four calendar days",start: start,end: end)
    let document = DiagramDocument(tasks: [task],metadata: ["calendarTimeZone": zone.identifier])
    let one = try DiagramPlanProjection.document(document), two = try DiagramPlanProjection.document(document)
    #expect(one.pages[0].elements.map(\.id) == two.pages[0].elements.map(\.id))
    let width = Double(one.pages[0].metadata["dayWidth"]!)!, bar = one.pages[0].elements.first { $0.taskID == task.id && $0.metadata["taskLabel"] != "true" }!
    #expect(bar.frame?.width == width*4)
    #expect(String(decoding: try MermaidCodec.encodeGantt(document).data,as: UTF8.self).contains("4d"))
}
@Test @MainActor func headlessPencilKitExportFailsClosedWithoutCrashing() throws {
    #if os(macOS)
    if Bundle.main.bundleIdentifier == nil {
        do { _ = try DiagramNativeInk.bounds(Data([1,2,3])); Issue.record("Headless PencilKit entered its unsafe bundle path") }
        catch DiagramError.unsupported { }
    }
    #endif
}
@Test @MainActor func chineseConnectionLabelIsCompleteInNativePDF() async throws {
    let a = DiagramElement(title: "A",frame: .init(x: 0,y: 0)), b = DiagramElement(title: "B",frame: .init(x: 320,y: 120))
    let document = DiagramDocument(pages: [.init(structure: .free,elements: [a,b],connections: [.init(from: a.id,to: b.id,label: "调研依据")])])
    let pdf = try await DiagramExchange.export(document,format: .pdf)
    #expect(PDFDocument(data: pdf.data)?.string?.contains("调研依据") == true)
    let svg = try await DiagramExchange.export(document,format: .svg)
    #expect(String(decoding: svg.data,as: UTF8.self).contains("调研依据"))
}

@Test @MainActor func projectedPlanPDFKeepsHeadingAndCalendarLabels() async throws {
    let original = DiagramExamples.library()
    for board in [true,false] {
        let plan = try DiagramPlanProjection.document(original,board: board)
        let output = try await DiagramExchange.export(plan,format: .pdf)
        let text = try #require(PDFDocument(data: output.data)?.string)
        #expect(text.contains(original.title))
        if !board {
            let ticks = plan.pages[0].elements.filter { $0.kind == .text && $0.frame?.y == 52 }
            #expect(!ticks.isEmpty)
            for tick in ticks { #expect(text.contains(tick.title),"Missing calendar tick \(tick.title)") }
        }
    }
}
@Test @MainActor func imageHeavyExportNeverDropsEarlierImagesWhenCacheEvicts() async throws {
    var descriptors: [DiagramAsset] = [], bytes: [UUID: Data] = [:], nodes: [DiagramElement] = []
    for index in 0..<20 {
        let context = CGContext(data: nil,width: 1_024,height: 1_024,bitsPerComponent: 8,bytesPerRow: 4_096,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: Double(index)/100,green: 0.2,blue: 0.9,alpha: 1)); context.fill(.init(x: 0,y: 0,width: 1_024,height: 1_024))
        let storage = NSMutableData(), destination = CGImageDestinationCreateWithData(storage,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(destination,context.makeImage()!,nil); #expect(CGImageDestinationFinalize(destination))
        let data = storage as Data, asset = DiagramAsset(fileName: "tile\(index).png",mediaType: "image/png",byteCount: data.count,sha256: DiagramCodec.digest(data))
        descriptors.append(asset); bytes[asset.id] = data
        nodes.append(.init(title: "Tile \(index)",frame: .init(x: Double(index%5)*200,y: Double(index/5)*200,width: 160,height: 160),content: [.image(assetID: asset.id,caption: "")]))
    }
    let document = DiagramDocument(pages: [.init(structure: .free,elements: nodes)],assets: descriptors)
    let result = try await DiagramExchange.export(document,format: .png,assets: InMemoryDiagramAssets(bytes))
    let source = CGImageSourceCreateWithData(result.data as CFData,nil)!, image = CGImageSourceCreateImageAtIndex(source,0,nil)!
    let context = CGContext(data: nil,width: image.width,height: image.height,bitsPerComponent: 8,bytesPerRow: image.width*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image,in: .init(x: 0,y: 0,width: image.width,height: image.height))
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    var colors: [UInt32: Int] = [:]
    for index in 0..<(image.width*image.height) {
        let r = pixels[index*4], g = pixels[index*4+1], b = pixels[index*4+2]
        if r < 120 && b > 180 && g < 100 { colors[UInt32(r)<<16 | UInt32(g)<<8 | UInt32(b),default: 0] += 1 }
    }
    // Count every distinct source tile, independent of aspect-fit thumbnail size and antialiased edge pixels.
    #expect(colors.values.filter { $0 > 1_000 }.count == descriptors.count)
}
@Test func svgConvertsNonPNGImageToAReadableEmbeddedThumbnail() async throws {
    let source = CGImageSourceCreateWithData(DiagramExamples.pixelPNG as CFData,nil)!, image = CGImageSourceCreateImageAtIndex(source,0,nil)!
    let storage = NSMutableData(), destination = CGImageDestinationCreateWithData(storage,UTType.gif.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(destination,image,nil); #expect(CGImageDestinationFinalize(destination))
    let data = storage as Data, asset = DiagramAsset(fileName: "source.gif",mediaType: "image/gif",byteCount: data.count,sha256: DiagramCodec.digest(data))
    let document = DiagramDocument(pages: [.init(elements: [.init(title: "GIF",content: [.image(assetID: asset.id,caption: "")])])],assets: [asset])
    let output = try await DiagramExchange.export(document,format: .svg,assets: InMemoryDiagramAssets([asset.id:data]))
    #expect(output.issues.contains { $0.code == "imageConverted" })
    #expect(String(decoding: output.data,as: UTF8.self).contains("data:image/png;base64,"))
}
@Test func editableExchangeUsesActualThemeAndPickerColors() async throws {
    let a = DiagramElement(title: "A",style: .init(fill: "ABCDEF",stroke: "123456",text: "onAccent")), b = DiagramElement(title: "B")
    let document = DiagramDocument(pages: [.init(elements: [a,b],connections: [.init(from: a.id,to: b.id,color: "654321")])])
    let drawIO = try DrawIOCodec.encode(document), xml = String(decoding: drawIO.data,as: UTF8.self)
    #expect(xml.contains("fillColor=#ABCDEF;") && xml.contains("strokeColor=#123456;") && xml.contains("strokeColor=#654321;"))
    let freeMind = try OutlineCodec.encode(document,page: document.pages[0],format: .freemind)
    #expect(String(decoding: freeMind.data,as: UTF8.self).contains("BACKGROUND_COLOR=\"#ABCDEF\""))
    let xmind = try await XMindCodec.encode(document,resolver: nil), entries = try DiagramZIP.unpack(xmind.data)
    #expect(String(decoding: entries["content.json"]!,as: UTF8.self).contains("#ABCDEF"))
}
