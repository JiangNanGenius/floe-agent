// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && DEBUG
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import XCTest
import FloeLaTeXEngine
@testable import FloeApp

/// Real CoreGraphics output/readback. No Simulator is created by this test;
/// Root chooses the normal exact App-host product and canonical device.
final class LaTeXApplePDFRendererAppTests: XCTestCase {
    private func protected<T>(_ body: @escaping () throws -> T) throws -> T {
        try PDFKitGate.run { try withPDFExceptionGuard(body) }
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NativePDFProof-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url // Retain real output/evidence until Root exports it.
    }
    private func json(_ fonts: [[String: Any]], _ pages: [[String: Any]], assets: [[String: Any]] = []) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocol":"floe.tex.display-list", "version":1,
            "units":"bp", "origin":"top-left", "fonts":fonts, "pages":pages, "assets":assets], options: [.sortedKeys])
    }
    private func special(_ value: String, x: Double = 0, y: Double = 0) -> [String: Any] {
        ["kind":"special", "x":x, "y":y, "dataBase64":Data(value.utf8).base64EncodedString()]
    }
    private func glyphFont() throws -> (CTFont, [String: Any], [UInt16]) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        let name = CTFontCopyPostScriptName(font) as String
        let chars = Array("Floe".utf16); var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        try XCTUnwrap(CTFontGetGlyphsForCharacters(font, chars, &glyphs, chars.count) ? true : nil)
        return (font, ["id":7, "name":name, "postScriptName":name, "size":20, "faceIndex":0], glyphs)
    }
    private func fixtures(_ root: URL) throws -> [String: URL] {
        let image = root.appendingPathComponent("blue.png"), pdf = root.appendingPathComponent("green.pdf")
        let color = CGColorSpaceCreateDeviceRGB()
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 64, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        bitmap.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let frame = try XCTUnwrap(bitmap.makeImage())
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithURL(image as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, frame, nil); XCTAssertTrue(CGImageDestinationFinalize(encoder))
        try protected {
            var box = CGRect(x: 0, y: 0, width: 24, height: 18)
            let context = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &box, nil))
            context.beginPDFPage(nil); context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            context.fill(box); context.endPDFPage(); context.closePDF()
        }
        return ["image":image, "pdf":pdf]
    }

    func testActualGlyphsRulesColorsImagesAndPDFPagesProduceRealNativePDF() throws {
        let root = try folder(), media = try fixtures(root), (_, font, glyphs) = try glyphFont()
        let native: [String: Any] = ["kind":"glyphRun", "fontID":7, "glyphs":glyphs,
            "x":[20,35,40,52], "y":[35,35,35,35]]
        let ops: [[String: Any]] = [native, special("color push rgb 1 0 0"),
            ["kind":"rule", "x":20, "y":45, "width":60, "height":10], special("color pop"),
            special("pdf:image matrix 2 0 0 2 0 0 page 1 (blue.png)", x: 20, y: 110),
            special("pdf:image matrix 1 0 0 1 0 0 page 1 pagebox cropbox (green.pdf)", x: 100, y: 110)]
        let data = try json([font], [["width":200,"height":160,"ops":ops],
            ["width":160,"height":200,"ops":[["kind":"rule","x":12,"y":12,"width":10,"height":10]]]],
            assets: [["name":"blue.png","path":try XCTUnwrap(media["image"]).path,"kind":"image"],
                     ["name":"green.pdf","path":try XCTUnwrap(media["pdf"]).path,"kind":"pdf"]])
        let output = root.appendingPathComponent("actual.pdf")
        let receipt = try protected { try LaTeXApplePDFRenderer.render(displayListData: data, allowedRoots: [root], outputURL: output) }
        XCTAssertEqual(receipt.pageCount, 2); XCTAssertEqual(receipt.glyphCount, 4); XCTAssertEqual(receipt.legacyGlyphCount, 0)
        XCTAssertEqual(receipt.imageCount, 1); XCTAssertEqual(receipt.pdfImportCount, 1)
        XCTAssertGreaterThan(receipt.bytes, 1000)
        try protected {
            let document = try XCTUnwrap(CGPDFDocument(output as CFURL)); XCTAssertEqual(document.numberOfPages, 2)
            let first = try XCTUnwrap(document.page(at: 1)), second = try XCTUnwrap(document.page(at: 2))
            XCTAssertEqual(first.getBoxRect(.mediaBox).size, CGSize(width: 200, height: 160))
            XCTAssertEqual(second.getBoxRect(.mediaBox).size, CGSize(width: 160, height: 200))
            let raster = try XCTUnwrap(CGContext(data: nil, width: 200, height: 160, bitsPerComponent: 8,
                bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            raster.setFillColor(CGColor(gray: 1, alpha: 1)); raster.fill(CGRect(x: 0, y: 0, width: 200, height: 160))
            raster.drawPDFPage(first)
            let pixels = try XCTUnwrap(raster.data).assumingMemoryBound(to: UInt8.self)
            var red=0, green=0, blue=0, black=0
            for index in 0..<(200*160) {
                let r=pixels[index*4], g=pixels[index*4+1], b=pixels[index*4+2]
                if r>200 && g<60 && b<60 {red+=1}; if g>200 && r<60 && b<60 {green+=1}
                if b>200 && r<60 && g<60 {blue+=1}; if r<80 && g<80 && b<80 {black+=1}
            }
            XCTAssertGreaterThan(red, 400, "Real rule color/area must survive PDF readback")
            XCTAssertGreaterThan(green, 200, "Real imported PDF paint must survive")
            XCTAssertGreaterThan(blue, 500, "Real decoded PNG/matrix paint must survive")
            XCTAssertGreaterThan(black, 20, "Real native glyph ink must survive")
        }
        let attachment = XCTAttachment(data: try JSONEncoder().encode(receipt), uniformTypeIdentifier: "public.json")
        attachment.name="Actual Apple PDF renderer receipt"; attachment.lifetime = .keepAlways; add(attachment)
        print("FLOE_NATIVE_PDF_PROOF=" + root.path)
    }

    func testUnsupportedSpecialCancellationAndEscapeNeverPublishAReplacementPDF() throws {
        let root = try folder(), output = root.appendingPathComponent("blocked.pdf")
        let unsupported = try json([], [["width":100,"height":100,"ops":[special("ps: arbitrary PostScript")]]])
        XCTAssertThrowsError(try protected { try LaTeXApplePDFRenderer.render(displayListData: unsupported, allowedRoots:[root], outputURL:output) }) { error in
            guard let native = error as? LaTeXApplePDFError else { return XCTFail("Expected native PDF error") }
            if case .unsupportedSpecial = native {} else { XCTFail("Expected explicit unsupported-special failure") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let empty = try json([], [["width":100,"height":100,"ops":[]]])
        XCTAssertThrowsError(try protected { try LaTeXApplePDFRenderer.render(displayListData: empty, allowedRoots:[root], outputURL:output, cancellation:{true}) }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let escaped = root.deletingLastPathComponent().appendingPathComponent("forbidden-"+UUID().uuidString+".pdf")
        XCTAssertThrowsError(try protected { try LaTeXApplePDFRenderer.render(displayListData: empty, allowedRoots:[root], outputURL:escaped) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
        let prior = Data("retained output bytes".utf8); try prior.write(to: output)
        XCTAssertThrowsError(try protected { try LaTeXApplePDFRenderer.render(displayListData: empty, allowedRoots:[root], outputURL:output) })
        XCTAssertEqual(try Data(contentsOf: output), prior)
    }

    func testExactPFBFontProbeAndLegacyOutlineProvider() throws {
        guard let path = ProcessInfo.processInfo.environment["FLOE_NATIVE_LATEX_PFB_PROOF"] else {
            throw XCTSkip("Root supplies the exact exported cmr10.pfb from this native article/math build.")
        }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        XCTAssertEqual(file.path, file.resolvingSymlinksInPath().path)
        let bytes = try Data(contentsOf: file), probe = try LaTeXApplePDFRenderer.probeFont(data: bytes)
        let root = try folder()
        let font: [String:Any] = ["id":11,"name":"cmr10","path":file.path,"size":30,"faceIndex":0,"kind":"legacy","encoding":"builtin"]
        let op: [String:Any] = ["kind":"legacyGlyph","fontID":11,"character":65,"glyphName":"A","x":20,"y":50]
        let data = try json([font], [["width":100,"height":100,"ops":[op]]])
        // The production engine's adapter calls the exact FTL FreeType C ABI;
        // no made-up outline or Unicode fallback is injected in this proof.
        let result = try protected { try LaTeXApplePDFRenderer.render(displayListData:data,
            allowedRoots:[root,file.deletingLastPathComponent()], outputURL:root.appendingPathComponent("legacy.pdf"),
            legacyOutlineProvider:LaTeXAppleNativeEngine.legacyGlyphOutline) }
        XCTAssertEqual(result.legacyGlyphCount, 1); XCTAssertEqual(result.pageCount, 1)
        let attachment=XCTAttachment(data:try JSONEncoder().encode(probe),uniformTypeIdentifier:"public.json")
        attachment.name="Actual target PFB CoreGraphics/CoreText probe";attachment.lifetime = .keepAlways;add(attachment)
        print("FLOE_NATIVE_PFB_PROOF="+root.path)
    }


    /// Exact 20 special byte strings from the retained real article XDV.
    /// Glyphs/positions are a small native fixture; Root separately qualifies
    /// the full original's real XeTeX fonts and TFM positions through the App.
    func testActualArticleSpecialsKeepMetadataDestinationsBookmarksLinksAndView() throws {
        let texts = [
            "pdf:pagesize width 597.50787pt height 845.04684pt",
            "pdf:docinfo<</Title()/Subject()/Creator(LaTeX with hyperref)/Author()/Keywords()>>",
            "pdfcolorstackinit 1 page direct (0 g 0 G)",
            "pdf:dest (page.1) [@thispage /XYZ @xpos @ypos null]",
            "pdf:majorversion 1",
            "pdf:minorversion 5",
            "dvipdfmx:config C 0x0010",
            "pdf:outline [-] 1<</Title(\\376\\377\\000I\\000n\\000t\\000r\\000o\\000d\\000u\\000c\\000t\\000i\\000o\\000n)/A<</S/GoTo/D(section.1)>>>>",
            "pdf:outline [-] 1<</Title(\\376\\377\\000M\\000e\\000t\\000h\\000o\\000d\\000s)/A<</S/GoTo/D(section.2)>>>>",
            "pdf:outline [-] 1<</Title(\\376\\377\\000R\\000e\\000s\\000u\\000l\\000t\\000s)/A<</S/GoTo/D(section.3)>>>>",
            "pdf:outline [-] 1<</Title(\\376\\377\\000C\\000o\\000n\\000c\\000l\\000u\\000s\\000i\\000o\\000n)/A<</S/GoTo/D(section.4)>>>>",
            "pdf:docview<</OpenAction[@page1/Fit]/PageMode/UseOutlines>>",
            "pdf:dest (Doc-Start) [@thispage /XYZ @xpos @ypos null]",
            "pdf:dest (section.1) [@thispage /XYZ @xpos @ypos null]",
            "pdf:dest (section.2) [@thispage /XYZ @xpos @ypos null]",
            "pdf:dest (equation.2.1) [@thispage /XYZ @xpos @ypos null]",
            "pdf:dest (section.3) [@thispage /XYZ @xpos @ypos null]",
            "pdf:bann<</Type/Annot/Subtype/Link/Border[0 0 1]/H/I/C[1 0 0]/A<</S/GoTo/D(equation.2.1)>>>>",
            "pdf:eann",
            "pdf:dest (section.4) [@thispage /XYZ @xpos @ypos null]"
        ]
        let root = try folder(), (_,font,glyphs) = try glyphFont()
        let width=597.50787*72/72.27,height=845.04684*72/72.27
        var ops=[[String:Any]]()
        for (index,text) in texts.enumerated() {
            ops.append(special(text,x:Double(40+index*5),y:Double(80+index*8)))
            if text.hasPrefix("pdf:bann") {
                ops.append(["kind":"glyphRun","fontID":7,"glyphs":glyphs,
                    "x":[40,55,60,72],"y":[260,260,260,260]])
            }
        }
        let input=try json([font],[["width":width,"height":height,"ops":ops]])
        let output=root.appendingPathComponent("actual-special-semantics.pdf")
        let receipt=try protected {try LaTeXApplePDFRenderer.render(displayListData:input,allowedRoots:[root],outputURL:output)}
        let navigation=try XCTUnwrap(receipt.navigation)
        XCTAssertEqual(receipt.pageCount,1);XCTAssertEqual(receipt.glyphCount,4);XCTAssertEqual(receipt.consumedSpecials,20)
        XCTAssertEqual(navigation.metadataKeys,["Author","Creator","Keywords","Subject","Title"])
        XCTAssertEqual(navigation.namedDestinationCount,7);XCTAssertEqual(navigation.outlineCount,4)
        XCTAssertEqual(navigation.linkAnnotationCount,1);XCTAssertEqual(navigation.emittedVersion,"1.5")
        XCTAssertTrue(navigation.compatibilityNotes.contains{$0.contains("0x0010") && $0.contains("retained")})
        XCTAssertTrue(try Data(contentsOf:output).starts(with:Data("%PDF-1.5".utf8)))
        try protected {
            let graphics=try XCTUnwrap(CGPDFDocument(output as CFURL)),catalog=try XCTUnwrap(graphics.catalog)
            var mode:UnsafePointer<CChar>?,open:CGPDFArrayRef?,fit:UnsafePointer<CChar>?
            XCTAssertTrue(CGPDFDictionaryGetName(catalog,"PageMode",&mode));XCTAssertEqual(String(cString:try XCTUnwrap(mode)),"UseOutlines")
            XCTAssertTrue(CGPDFDictionaryGetArray(catalog,"OpenAction",&open))
            XCTAssertTrue(CGPDFArrayGetName(try XCTUnwrap(open),1,&fit));XCTAssertEqual(String(cString:try XCTUnwrap(fit)),"Fit")
            let info=try XCTUnwrap(graphics.info)
            for (key,expected) in [("Creator","LaTeX with hyperref"),("Title",""),("Author",""),("Subject",""),("Keywords","")] {
                var value:CGPDFStringRef?;XCTAssertTrue(CGPDFDictionaryGetString(info,key,&value))
                XCTAssertEqual(try XCTUnwrap(CGPDFStringCopyTextString(try XCTUnwrap(value))) as String,expected)
            }
            let document=try XCTUnwrap(PDFDocument(url:output)),outlines=try XCTUnwrap(document.outlineRoot)
            XCTAssertEqual(outlines.numberOfChildren,4)
            let titles=["Introduction","Methods","Results","Conclusion"]
            let sourceIndices=[13,14,16,19]
            for index in 0..<4 {
                let outline=try XCTUnwrap(outlines.child(at:index));XCTAssertEqual(outline.label,titles[index])
                let action=try XCTUnwrap(outline.action as? PDFActionGoTo)
                XCTAssertEqual(document.index(for:try XCTUnwrap(action.destination.page)),0)
                XCTAssertEqual(action.destination.point.x,Double(40+sourceIndices[index]*5),accuracy:0.001)
                XCTAssertEqual(action.destination.point.y,height-Double(80+sourceIndices[index]*8),accuracy:0.001)
            }
            let page=try XCTUnwrap(document.page(at:0));XCTAssertEqual(page.annotations.count,1)
            let link=try XCTUnwrap(page.annotations.first);XCTAssertEqual(link.type,"Link")
            XCTAssertEqual(link.border?.lineWidth,1);XCTAssertGreaterThan(link.bounds.width,30);XCTAssertGreaterThan(link.bounds.height,10)
            let action=try XCTUnwrap(link.action as? PDFActionGoTo)
            XCTAssertEqual(action.destination.point.x,115,accuracy:0.001)
            XCTAssertEqual(action.destination.point.y,height-200,accuracy:0.001)
            let raster=try XCTUnwrap(CGContext(data:nil,width:596,height:842,bitsPerComponent:8,bytesPerRow:596*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            raster.setFillColor(CGColor(gray:1,alpha:1));raster.fill(CGRect(x:0,y:0,width:596,height:842))
            raster.drawPDFPage(try XCTUnwrap(graphics.page(at:1)))
            let pixels=try XCTUnwrap(raster.data).assumingMemoryBound(to:UInt8.self)
            var black=0
            for n in 0..<(596*842) {if pixels[n*4]<80 && pixels[n*4+1]<80 && pixels[n*4+2]<80 {black += 1}}
            XCTAssertGreaterThan(black,20,"Incremental navigation must retain real native glyph paint")
        }
        try JSONEncoder().encode(receipt).write(to:root.appendingPathComponent("NavigationReceipt.json"))
        let attachment=XCTAttachment(data:try Data(contentsOf:output),uniformTypeIdentifier:"com.adobe.pdf")
        attachment.name="Native PDF actual article special semantics";attachment.lifetime = .keepAlways;add(attachment)
        print("FLOE_NATIVE_HYPERREF_PROOF="+root.path)
    }

    func testNativeNavigationRejectsExecutableActionsMissingTargetsAndEmptyLinks() throws {
        let root=try folder()
        let cases=[
            ["pdf:docview<</OpenAction<</S/JavaScript/JS(app.alert(1))>>>>"],
            ["pdf:outline 1<</Title(Test)/A<</S/Launch/F(evil)>>>>"],
            ["pdf:bann<</Subtype/Link/A<</S/URI/URI(https://example.invalid)>>>>","pdf:eann"],
            ["pdf:outline 1<</Title(Test)/A<</S/GoTo/D(missing)>>>>"],
            ["pdf:dest (target) [@thispage /XYZ @xpos @ypos null]","pdf:bann<</Subtype/Link/A<</S/GoTo/D(target)>>>>","pdf:eann"],
            ["dvipdfmx:config C 0x4000"],
            ["pdfcolorstackinit 1 page direct (0 g 0 G currentfile)"]
        ]
        for (index,values) in cases.enumerated() {
            let output=root.appendingPathComponent("rejected-\(index).pdf")
            let input=try json([],[["width":100,"height":100,"ops":values.map{special($0,x:10,y:20)}]])
            XCTAssertThrowsError(try protected{try LaTeXApplePDFRenderer.render(displayListData:input,allowedRoots:[root],outputURL:output)})
            XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
        }
    }
}
#endif
