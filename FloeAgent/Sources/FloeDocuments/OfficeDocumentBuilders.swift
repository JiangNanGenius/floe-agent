// FloeDocuments — native, dependency-bounded Office Open XML builders.

import Foundation
import ZIPFoundation

public struct OfficeWorkbookSheet: Codable, Sendable, Equatable {
    public var name: String
    public var rows: [[String]]

    public init(name: String, rows: [[String]]) {
        self.name = name
        self.rows = rows
    }
}

public struct OfficePresentationSlide: Codable, Sendable, Equatable {
    public var title: String
    public var bullets: [String]
    public var notes: String?

    public init(title: String, bullets: [String] = [], notes: String? = nil) {
        self.title = title
        self.bullets = bullets
        self.notes = notes
    }
}

/// Creates small, standards-based Office files without downloading or
/// executing a document runtime. The resulting packages remain editable in
/// Office, iWork, LibreOffice and Floe's basic editor.
public enum OfficeDocumentBuilder {
    public static func createWord(
        at url: URL,
        title: String,
        paragraphs: [String]
    ) throws {
        let body = ([wordParagraph(title, style: "Title")] + paragraphs.map {
            wordParagraph($0, style: nil)
        }).joined()
        let entries: [String: String] = [
            "[Content_Types].xml": xmlHeader + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>"#,
            "_rels/.rels": xmlHeader + relationships([
                ("rId1", officeRelationship + "/officeDocument", "word/document.xml")
            ]),
            "word/_rels/document.xml.rels": xmlHeader + relationships([]),
            "word/styles.xml": xmlHeader + wordStyles,
            "word/document.xml": xmlHeader + #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>"# + body + #"<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body></w:document>"#
        ]
        try writePackage(entries, to: url)
        _ = try OfficeDocumentService.inspect(url: url)
    }

    public static func createWorkbook(
        at url: URL,
        sheets: [OfficeWorkbookSheet]
    ) throws {
        let safeSheets = sheets.isEmpty ? [OfficeWorkbookSheet(name: "Sheet1", rows: [[]])] : sheets
        var entries: [String: String] = [:]
        let overrides = safeSheets.indices.map {
            #"<Override PartName="/xl/worksheets/sheet\#($0 + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
        }.joined()
        entries["[Content_Types].xml"] = xmlHeader + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>"# + overrides + "</Types>"
        entries["_rels/.rels"] = xmlHeader + relationships([
            ("rId1", officeRelationship + "/officeDocument", "xl/workbook.xml")
        ])
        entries["xl/workbook.xml"] = xmlHeader + #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView/></bookViews><sheets>"# + safeSheets.enumerated().map { index, sheet in
            #"<sheet name="\#(XMLText.escapeAttribute(normalizedSheetName(sheet.name, index: index)))" sheetId="\#(index + 1)" r:id="rId\#(index + 1)"/>"#
        }.joined() + "</sheets><calcPr calcId=\"191029\" fullCalcOnLoad=\"1\"/></workbook>"
        entries["xl/_rels/workbook.xml.rels"] = xmlHeader + relationships(
            safeSheets.indices.map { ("rId\($0 + 1)", officeRelationship + "/worksheet", "worksheets/sheet\($0 + 1).xml") }
                + [("rId\(safeSheets.count + 1)", officeRelationship + "/styles", "styles.xml")]
        )
        entries["xl/styles.xml"] = xmlHeader + workbookStyles
        for (index, sheet) in safeSheets.enumerated() {
            entries["xl/worksheets/sheet\(index + 1).xml"] = xmlHeader + worksheetXML(sheet.rows)
        }
        try writePackage(entries, to: url)
        _ = try OfficeDocumentService.inspect(url: url)
    }

    public static func createPresentation(
        at url: URL,
        title: String,
        slides: [OfficePresentationSlide]
    ) throws {
        let safeSlides = slides.isEmpty
            ? [OfficePresentationSlide(title: title, bullets: [])]
            : slides
        var entries: [String: String] = [:]
        let slideOverrides = safeSlides.indices.map {
            #"<Override PartName="/ppt/slides/slide\#($0 + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"#
        }.joined()
        let notesOverrides = safeSlides.indices.map {
            #"<Override PartName="/ppt/notesSlides/notesSlide\#($0 + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml"/>"#
        }.joined()
        entries["[Content_Types].xml"] = xmlHeader + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/notesMasters/notesMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.notesMaster+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>"# + slideOverrides + notesOverrides + "</Types>"
        entries["_rels/.rels"] = xmlHeader + relationships([
            ("rId1", officeRelationship + "/officeDocument", "ppt/presentation.xml")
        ])
        entries["ppt/presentation.xml"] = xmlHeader + #"<p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>"# + safeSlides.indices.map {
            #"<p:sldId id="\#(256 + $0)" r:id="rId\#($0 + 2)"/>"#
        }.joined() + #"</p:sldIdLst><p:notesMasterIdLst><p:notesMasterId r:id="rId\#(safeSlides.count + 2)"/></p:notesMasterIdLst><p:sldSz cx="12192000" cy="6858000" type="screen16x9"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>"#
        entries["ppt/_rels/presentation.xml.rels"] = xmlHeader + relationships(
            [("rId1", officeRelationship + "/slideMaster", "slideMasters/slideMaster1.xml")]
                + safeSlides.indices.map { ("rId\($0 + 2)", officeRelationship + "/slide", "slides/slide\($0 + 1).xml") }
                + [("rId\(safeSlides.count + 2)", officeRelationship + "/notesMaster", "notesMasters/notesMaster1.xml")]
        )
        entries["ppt/slideMasters/slideMaster1.xml"] = xmlHeader + slideMaster
        entries["ppt/slideMasters/_rels/slideMaster1.xml.rels"] = xmlHeader + relationships([
            ("rId1", officeRelationship + "/slideLayout", "../slideLayouts/slideLayout1.xml"),
            ("rId2", officeRelationship + "/theme", "../theme/theme1.xml")
        ])
        entries["ppt/slideLayouts/slideLayout1.xml"] = xmlHeader + slideLayout
        entries["ppt/slideLayouts/_rels/slideLayout1.xml.rels"] = xmlHeader + relationships([
            ("rId1", officeRelationship + "/slideMaster", "../slideMasters/slideMaster1.xml")
        ])
        entries["ppt/theme/theme1.xml"] = xmlHeader + officeTheme
        entries["ppt/notesMasters/notesMaster1.xml"] = xmlHeader + notesMaster
        entries["ppt/notesMasters/_rels/notesMaster1.xml.rels"] = xmlHeader + relationships([
            ("rId1", officeRelationship + "/theme", "../theme/theme1.xml")
        ])
        for (index, slide) in safeSlides.enumerated() {
            entries["ppt/slides/slide\(index + 1).xml"] = xmlHeader + slideXML(slide, deckTitle: title)
            entries["ppt/slides/_rels/slide\(index + 1).xml.rels"] = xmlHeader + relationships([
                ("rId1", officeRelationship + "/slideLayout", "../slideLayouts/slideLayout1.xml"),
                ("rId2", officeRelationship + "/notesSlide", "../notesSlides/notesSlide\(index + 1).xml")
            ])
            entries["ppt/notesSlides/notesSlide\(index + 1).xml"] = xmlHeader + notesSlideXML(slide.notes ?? "")
            entries["ppt/notesSlides/_rels/notesSlide\(index + 1).xml.rels"] = xmlHeader + relationships([
                ("rId1", officeRelationship + "/notesMaster", "../notesMasters/notesMaster1.xml"),
                ("rId2", officeRelationship + "/slide", "../slides/slide\(index + 1).xml")
            ])
        }
        try writePackage(entries, to: url)
        _ = try OfficeDocumentService.inspect(url: url)
    }

    private static let xmlHeader = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
    private static let officeRelationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    private static func relationships(_ values: [(String, String, String)]) -> String {
        #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + values.map { id, type, target in
                #"<Relationship Id="\#(id)" Type="\#(type)" Target="\#(XMLText.escapeAttribute(target))"/>"#
            }.joined()
            + "</Relationships>"
    }

    private static func writePackage(_ strings: [String: String], to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".floe-office-create-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        let archive = try Archive(url: temporary, accessMode: .create)
        for path in strings.keys.sorted() {
            try archive.addFloeEntry(path: path, data: Data((strings[path] ?? "").utf8))
        }
        if manager.fileExists(atPath: url.path) {
            throw CocoaError(.fileWriteFileExists)
        }
        try manager.moveItem(at: temporary, to: url)
    }

    private static func wordParagraph(_ text: String, style: String?) -> String {
        let styleXML = style.map { #"<w:pPr><w:pStyle w:val="\#($0)"/></w:pPr>"# } ?? ""
        return #"<w:p>\#(styleXML)<w:r><w:t xml:space="preserve">\#(XMLText.escape(text))</w:t></w:r></w:p>"#
    }

    private static let wordStyles = #"<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="PingFang SC"/><w:sz w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style><w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:rPr><w:b/><w:sz w:val="52"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style></w:styles>"#

    private static func normalizedSheetName(_ value: String, index: Int) -> String {
        let forbidden = CharacterSet(charactersIn: "[]:*?/\\")
        let cleaned = value.components(separatedBy: forbidden).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "Sheet\(index + 1)" : cleaned).prefix(31))
    }

    private static func worksheetXML(_ rows: [[String]]) -> String {
        let rowXML = rows.prefix(10_000).enumerated().map { rowIndex, row in
            let cells = row.prefix(256).enumerated().map { columnIndex, value in
                let ref = columnName(columnIndex) + String(rowIndex + 1)
                if value.hasPrefix("=") {
                    return #"<c r="\#(ref)"><f>\#(XMLText.escape(String(value.dropFirst())))</f></c>"#
                }
                if Double(value) != nil, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    return #"<c r="\#(ref)"><v>\#(XMLText.escape(value))</v></c>"#
                }
                return #"<c r="\#(ref)" t="inlineStr"><is><t xml:space="preserve">\#(XMLText.escape(value))</t></is></c>"#
            }.joined()
            return #"<row r="\#(rowIndex + 1)">\#(cells)</row>"#
        }.joined()
        return #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><sheetFormatPr defaultRowHeight="18"/><sheetData>\#(rowXML)</sheetData></worksheet>"#
    }

    private static func columnName(_ zeroBased: Int) -> String {
        var value = zeroBased + 1
        var result = ""
        while value > 0 {
            value -= 1
            result.insert(Character(UnicodeScalar(65 + value % 26)!), at: result.startIndex)
            value /= 26
        }
        return result
    }

    private static let workbookStyles = #"<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Arial"/></font><font><b/><color rgb="FFFFFFFF"/><sz val="11"/><name val="Arial"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF2563EB"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>"#

    private static func slideXML(_ slide: OfficePresentationSlide, deckTitle: String) -> String {
        let title = slide.title.isEmpty ? deckTitle : slide.title
        let body = slide.bullets.prefix(12).enumerated().map { index, bullet in
            #"<a:p><a:pPr lvl="0" marL="342900" indent="-285750"><a:buChar char="•"/></a:pPr><a:r><a:rPr lang="zh-CN" sz="2200"/><a:t>\#(XMLText.escape(bullet))</a:t></a:r><a:endParaRPr lang="zh-CN" sz="2200"/></a:p>"#
        }.joined()
        return #"<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="F8FAFC"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\#(textShape(id: 2, name: "Title", x: 685800, y: 457200, width: 10820400, height: 1143000, paragraphs: #"<a:p><a:r><a:rPr lang="zh-CN" sz="3600" b="1"><a:solidFill><a:srgbClr val="0F172A"/></a:solidFill></a:rPr><a:t>\#(XMLText.escape(title))</a:t></a:r><a:endParaRPr lang="zh-CN" sz="3600"/></a:p>"#))\#(textShape(id: 3, name: "Content", x: 914400, y: 1905000, width: 10210800, height: 3962400, paragraphs: body.isEmpty ? #"<a:p><a:endParaRPr lang="zh-CN" sz="2200"/></a:p>"# : body))</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"#
    }

    private static func textShape(id: Int, name: String, x: Int, y: Int, width: Int, height: Int, paragraphs: String) -> String {
        #"<p:sp><p:nvSpPr><p:cNvPr id="\#(id)" name="\#(name)"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="\#(x)" y="\#(y)"/><a:ext cx="\#(width)" cy="\#(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></p:spPr><p:txBody><a:bodyPr wrap="square" lIns="0" tIns="0" rIns="0" bIns="0" anchor="t"/><a:lstStyle/>\#(paragraphs)</p:txBody></p:sp>"#
    }

    private static func notesSlideXML(_ notes: String) -> String {
        let paragraph = #"<a:p><a:r><a:rPr lang="zh-CN" sz="1200"/><a:t>\#(XMLText.escape(notes))</a:t></a:r><a:endParaRPr lang="zh-CN" sz="1200"/></a:p>"#
        return #"<p:notes xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\#(textShape(id: 2, name: "Notes", x: 685800, y: 914400, width: 5486400, height: 7315200, paragraphs: paragraph))</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>"#
    }

    private static let slideLayout = #"<p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1"><p:cSld name="Blank"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"#
    private static let slideMaster = #"<p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld name="Floe"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMap accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" bg1="lt1" bg2="lt2" folHlink="folHlink" hlink="hlink" tx1="dk1" tx2="dk2"/><p:sldLayoutIdLst><p:sldLayoutId id="1" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle><a:lvl1pPr algn="l"><a:defRPr sz="3600" b="1"/></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr marL="342900" indent="-285750"><a:defRPr sz="2200"/></a:lvl1pPr></p:bodyStyle><p:otherStyle><a:defPPr><a:defRPr lang="zh-CN"/></a:defPPr></p:otherStyle></p:txStyles></p:sldMaster>"#
    private static let notesMaster = #"<p:notesMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld name="Floe Notes"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMap accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" bg1="lt1" bg2="lt2" folHlink="folHlink" hlink="hlink" tx1="dk1" tx2="dk2"/><p:notesStyle><a:lvl1pPr><a:defRPr sz="1200"/></a:lvl1pPr></p:notesStyle></p:notesMaster>"#
    private static let officeTheme = #"<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Floe"><a:themeElements><a:clrScheme name="Floe"><a:dk1><a:srgbClr val="0F172A"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="334155"/></a:dk2><a:lt2><a:srgbClr val="F8FAFC"/></a:lt2><a:accent1><a:srgbClr val="2563EB"/></a:accent1><a:accent2><a:srgbClr val="06B6D4"/></a:accent2><a:accent3><a:srgbClr val="10B981"/></a:accent3><a:accent4><a:srgbClr val="F59E0B"/></a:accent4><a:accent5><a:srgbClr val="8B5CF6"/></a:accent5><a:accent6><a:srgbClr val="EF4444"/></a:accent6><a:hlink><a:srgbClr val="2563EB"/></a:hlink><a:folHlink><a:srgbClr val="7C3AED"/></a:folHlink></a:clrScheme><a:fontScheme name="Floe"><a:majorFont><a:latin typeface="Arial"/><a:ea typeface="PingFang SC"/><a:cs typeface="Arial"/></a:majorFont><a:minorFont><a:latin typeface="Arial"/><a:ea typeface="PingFang SC"/><a:cs typeface="Arial"/></a:minorFont></a:fontScheme><a:fmtScheme name="Floe"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="accent1"/></a:solidFill><a:solidFill><a:schemeClr val="accent2"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="25400"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="38100"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="lt1"/></a:solidFill><a:solidFill><a:schemeClr val="lt2"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"#
}
