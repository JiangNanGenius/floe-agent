// FloeDocuments — native, dependency-bounded Office Open XML builders.

import Foundation
import Crypto
import ZIPFoundation

public struct OfficeWorkbookSheet: Codable, Sendable, Equatable {
    public var name: String
    public var rows: [[String]]

    public init(name: String, rows: [[String]]) {
        self.name = name
        self.rows = rows
    }
}

/// One editable chart series. Values are numbers; the embedded workbook keeps
/// the same values so an editor can round-trip the chart without recalculating
/// the deck.
public struct OfficePresentationChartSeries: Codable, Sendable, Equatable {
    public var name: String
    public var values: [Double]

    public init(name: String, values: [Double]) {
        self.name = name
        self.values = values
    }
}

/// An editable native bar, line or pie chart. The builder writes a standard
/// OOXML chart part plus an embedded .xlsx workbook and the relationship that
/// links them, so the chart stays editable instead of becoming a picture.
public struct OfficePresentationChart: Codable, Sendable, Equatable {
    public enum ChartType: String, Codable, Sendable, CaseIterable {
        case bar
        case line
        case pie
    }

    public var chartType: ChartType
    public var title: String?
    public var categories: [String]
    public var series: [OfficePresentationChartSeries]

    public init(
        chartType: ChartType,
        title: String? = nil,
        categories: [String],
        series: [OfficePresentationChartSeries]
    ) {
        self.chartType = chartType
        self.title = title
        self.categories = categories
        self.series = series
    }
}

/// A positioned object on one slide. The schema is additive: a slide without
/// `objects` produces exactly the deck that earlier builds produced.
public struct OfficePresentationObject: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case text
        case shape
        case image
        case chart
    }

    public enum Shape: String, Codable, Sendable, CaseIterable {
        case rectangle = "rect"
        case roundedRectangle = "roundRect"
        case ellipse
        case triangle
        case diamond
        case arrow
        case chevron
        case star = "star5"
    }

    /// Convenience layout presets on the 16:9 canvas (12192000 x 6858000 EMU).
    public enum Layout: String, Codable, Sendable, CaseIterable {
        case full
        case left
        case right
        case top
        case bottom
        case center
    }

    public var kind: Kind
    public var name: String?
    public var layout: Layout?
    /// EMU geometry (914400 EMU = 1 inch). Explicit values override `layout`.
    public var x: Int?
    public var y: Int?
    public var width: Int?
    public var height: Int?
    public var text: [String]?
    public var shape: Shape?
    public var fillColor: String?
    public var lineColor: String?
    public var textColor: String?
    /// Font size in points (1...200).
    public var fontSize: Double?
    public var bold: Bool?
    /// Workspace-relative image path. Resolved by document.presentation.createDeck;
    /// the builder itself consumes `imageBase64`.
    public var imagePath: String?
    /// Inline image bytes (base64). PNG, JPEG and GIF only; SVG is rejected.
    public var imageBase64: String?
    public var chart: OfficePresentationChart?

    public init(
        kind: Kind,
        name: String? = nil,
        layout: Layout? = nil,
        x: Int? = nil,
        y: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        text: [String]? = nil,
        shape: Shape? = nil,
        fillColor: String? = nil,
        lineColor: String? = nil,
        textColor: String? = nil,
        fontSize: Double? = nil,
        bold: Bool? = nil,
        imagePath: String? = nil,
        imageBase64: String? = nil,
        chart: OfficePresentationChart? = nil
    ) {
        self.kind = kind
        self.name = name
        self.layout = layout
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.text = text
        self.shape = shape
        self.fillColor = fillColor
        self.lineColor = lineColor
        self.textColor = textColor
        self.fontSize = fontSize
        self.bold = bold
        self.imagePath = imagePath
        self.imageBase64 = imageBase64
        self.chart = chart
    }
}

public struct OfficePresentationSlide: Codable, Sendable, Equatable {
    public var title: String
    public var bullets: [String]
    public var notes: String?
    /// Positioned text, shapes, images and editable charts. Optional so decks
    /// created by earlier tool schemas still decode and build unchanged.
    public var objects: [OfficePresentationObject]?

    public init(
        title: String,
        bullets: [String] = [],
        notes: String? = nil,
        objects: [OfficePresentationObject]? = nil
    ) {
        self.title = title
        self.bullets = bullets
        self.notes = notes
        self.objects = objects
    }
}

/// Creates small, standards-based Office files without downloading or
/// executing a document runtime. The resulting packages remain editable in
/// Office, iWork, LibreOffice and Floe's basic editor.
public enum OfficeDocumentBuilder {
    public static let presentationCanvasWidth = 12_192_000
    public static let presentationCanvasHeight = 6_858_000
    public static let maximumPresentationObjectsPerSlide = 32
    public static let maximumChartCategories = 64
    public static let maximumChartSeries = 8
    public static let maximumImageBytes = 8 * 1_024 * 1_024

    public static func createWord(
        at url: URL,
        title: String,
        paragraphs: [String]
    ) throws {
        let body = ([wordParagraph(title, style: "Title", isTitle: true)] + paragraphs.map {
            wordParagraph($0, style: nil, isTitle: false)
        }).joined()
        let entries: [String: String] = [
            "[Content_Types].xml": xmlHeader + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>"#,
            "_rels/.rels": xmlHeader + relationships([
                ("rId1", officeRelationship + "/officeDocument", "word/document.xml"),
                ("rId2", "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties", "docProps/core.xml")
            ]),
            "docProps/core.xml": xmlHeader + wordCoreProperties(title: title),
            "word/_rels/document.xml.rels": xmlHeader + relationships([
                ("rId1", officeRelationship + "/styles", "styles.xml"),
                ("rId2", officeRelationship + "/theme", "theme/theme1.xml")
            ]),
            "word/styles.xml": xmlHeader + wordStyles,
            "word/theme/theme1.xml": xmlHeader + wordTheme(eastAsiaFont: wordEastAsiaFont),
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
        try writePackageData(workbookEntries(safeSheets), to: url)
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
        var binary: [String: Data] = [:]
        var contentTypeDefaults: [String: String] = [
            "rels": "application/vnd.openxmlformats-package.relationships+xml",
            "xml": "application/xml"
        ]
        var chartOverrides: [String] = []
        var imageCounter = 0
        var chartCounter = 0
        var mediaByDigest: [String: (path: String, contentType: String)] = [:]

        let slideOverrides = safeSlides.indices.map {
            #"<Override PartName="/ppt/slides/slide\#($0 + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"#
        }.joined()
        let notesOverrides = safeSlides.indices.map {
            #"<Override PartName="/ppt/notesSlides/notesSlide\#($0 + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml"/>"#
        }.joined()
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
            var rels: [(String, String, String)] = [
                ("rId1", officeRelationship + "/slideLayout", "../slideLayouts/slideLayout1.xml"),
                ("rId2", officeRelationship + "/notesSlide", "../notesSlides/notesSlide\(index + 1).xml")
            ]
            var nextRelationship = 3
            var shapes = ""
            var nextShapeID = 4
            var mediaRelationships: [String: String] = [:]
            let objects = slide.objects ?? []
            guard objects.count <= maximumPresentationObjectsPerSlide else {
                throw OfficeDocumentError.invalidContent(
                    "slide \(index + 1) has more than \(maximumPresentationObjectsPerSlide) objects"
                )
            }
            for object in objects {
                let frame = try frame(for: object, slideIndex: index)
                let shapeID = nextShapeID
                nextShapeID += 1
                switch object.kind {
                case .text:
                    shapes += textShape(
                        id: shapeID,
                        name: object.name ?? "Text \(shapeID - 2)",
                        x: frame.x, y: frame.y, width: frame.width, height: frame.height,
                        paragraphs: try objectParagraphs(object, defaultColor: object.textColor ?? "0F172A"),
                        fillColor: sanitizedColor(object.fillColor),
                        lineColor: sanitizedColor(object.lineColor)
                    )
                case .shape:
                    shapes += presetShapeXML(
                        id: shapeID,
                        name: object.name ?? "Shape \(shapeID - 2)",
                        preset: object.shape?.rawValue ?? "rect",
                        frame: frame,
                        paragraphs: try objectParagraphs(
                            object,
                            defaultColor: object.textColor ?? (sanitizedColor(object.fillColor) == nil ? "0F172A" : "FFFFFF")
                        ),
                        fillColor: sanitizedColor(object.fillColor) ?? "2563EB",
                        lineColor: sanitizedColor(object.lineColor)
                    )
                case .image:
                    let data = try imageData(for: object)
                    let format = try OfficeImageFormat.detect(data)
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    let media: (path: String, contentType: String)
                    if let existing = mediaByDigest[digest] {
                        media = existing
                    } else {
                        imageCounter += 1
                        let path = "ppt/media/image\(imageCounter).\(format.fileExtension)"
                        media = (path, format.contentType)
                        mediaByDigest[digest] = media
                        binary[path] = data
                        contentTypeDefaults[format.fileExtension] = format.contentType
                    }
                    let relationshipID: String
                    if let existing = mediaRelationships[media.path] {
                        relationshipID = existing
                    } else {
                        relationshipID = "rId\(nextRelationship)"
                        nextRelationship += 1
                        mediaRelationships[media.path] = relationshipID
                        rels.append((relationshipID, officeRelationship + "/image", "../media/" + (media.path as NSString).lastPathComponent))
                    }
                    shapes += pictureXML(
                        id: shapeID,
                        name: object.name ?? "Image \(shapeID - 2)",
                        frame: frame,
                        relationshipID: relationshipID
                    )
                case .chart:
                    guard let chart = object.chart else {
                        throw OfficeDocumentError.invalidContent("chart object \(shapeID - 2) has no chart payload")
                    }
                    chartCounter += 1
                    let chartName = "chart\(chartCounter)"
                    let chartPath = "ppt/charts/\(chartName).xml"
                    let workbookName = "floe-chart-data-\(chartCounter).xlsx"
                    binary[chartPath] = Data(try chartSpaceXML(chart, chartName: chartName).utf8)
                    binary["ppt/charts/_rels/\(chartName).xml.rels"] = Data(
                        (xmlHeader + relationships([
                            ("rId1", officeRelationship + "/package", "../embeddings/\(workbookName)")
                        ])).utf8
                    )
                    binary["ppt/embeddings/\(workbookName)"] = try embeddedChartWorkbookData(chart)
                    contentTypeDefaults["xlsx"] = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                    chartOverrides.append(
                        #"<Override PartName="/\#(chartPath)" ContentType="application/vnd.openxmlformats-officedocument.drawingml.chart+xml"/>"#
                    )
                    let relationshipID = "rId\(nextRelationship)"
                    nextRelationship += 1
                    rels.append((relationshipID, officeRelationship + "/chart", "../charts/\(chartName).xml"))
                    shapes += graphicFrameXML(
                        id: shapeID,
                        name: object.name ?? "Chart \(shapeID - 2)",
                        frame: frame,
                        relationshipID: relationshipID
                    )
                }
            }
            entries["ppt/slides/slide\(index + 1).xml"] = xmlHeader + slideXML(
                slide, deckTitle: title, additionalShapes: shapes
            )
            entries["ppt/slides/_rels/slide\(index + 1).xml.rels"] = xmlHeader + relationships(rels)
            entries["ppt/notesSlides/notesSlide\(index + 1).xml"] = xmlHeader + notesSlideXML(slide.notes ?? "")
            entries["ppt/notesSlides/_rels/notesSlide\(index + 1).xml.rels"] = xmlHeader + relationships([
                ("rId1", officeRelationship + "/notesMaster", "../notesMasters/notesMaster1.xml"),
                ("rId2", officeRelationship + "/slide", "../slides/slide\(index + 1).xml")
            ])
        }

        let defaultTypes = contentTypeDefaults.keys.sorted().map {
            #"<Default Extension="\#($0)" ContentType="\#(XMLText.escapeAttribute(contentTypeDefaults[$0] ?? "application/octet-stream"))"/>"#
        }.joined()
        entries["[Content_Types].xml"] = xmlHeader + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"# + defaultTypes + #"<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/notesMasters/notesMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.notesMaster+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>"# + slideOverrides + notesOverrides + chartOverrides.joined() + "</Types>"
        try writePackage(entries, binary: binary, to: url)
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

    private static func writePackage(_ strings: [String: String], binary: [String: Data] = [:], to url: URL) throws {
        var parts: [String: Data] = [:]
        for (path, value) in strings {
            guard parts[path] == nil else {
                throw OfficeDocumentError.invalidContent("duplicate package part \(path)")
            }
            parts[path] = Data(value.utf8)
        }
        for (path, value) in binary {
            guard parts[path] == nil else {
                throw OfficeDocumentError.invalidContent("duplicate package part \(path)")
            }
            parts[path] = value
        }
        try writePackageData(parts, to: url)
    }

    private static func writePackageData(_ entries: [String: Data], to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".floe-office-create-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        let archive = try Archive(url: temporary, accessMode: .create)
        for path in entries.keys.sorted() {
            try archive.addFloeEntry(path: path, data: entries[path] ?? Data())
        }
        if manager.fileExists(atPath: url.path) {
            throw CocoaError(.fileWriteFileExists)
        }
        try manager.moveItem(at: temporary, to: url)
    }

    private static func zipData(_ entries: [String: Data]) throws -> Data {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory
            .appendingPathComponent(".floe-office-embedded-\(UUID().uuidString).xlsx")
        defer { try? manager.removeItem(at: temporary) }
        let archive = try Archive(url: temporary, accessMode: .create)
        for path in entries.keys.sorted() {
            try archive.addFloeEntry(path: path, data: entries[path] ?? Data())
        }
        return try Data(contentsOf: temporary)
    }

    // MARK: - Word

    private static func wordParagraph(_ text: String, style: String?, isTitle: Bool) -> String {
        let styleXML = style.map { #"<w:pPr><w:pStyle w:val="\#($0)"/></w:pPr>"# } ?? ""
        // Explicit per-run fonts: the engine's theme/docDefaults eastAsia
        // resolution is unreliable on iOS, so every generated run names the
        // installed CJK family directly. Without this Chinese glyphs render
        // as empty squares in the native editor.
        let runFonts = #"<w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="\#(XMLText.escapeAttribute(wordEastAsiaFont))"/></w:rPr>"#
        return #"<w:p>\#(styleXML)<w:r>\#(runFonts)<w:t xml:space="preserve">\#(XMLText.escape(text))</w:t></w:r></w:p>"#
    }

    /// East Asian font family written into every generated Word run and the
    /// document defaults. The previous "Source Han Sans SC" family is not
    /// installed on iOS, so the engine's fallback could render Chinese glyphs
    /// as empty squares. "PingFang SC" is the system CJK family on every
    /// supported iOS/iPadOS device (our entire target), and desktop Word
    /// substitutes an installed CJK font when a named family is missing, so
    /// generated documents stay readable in both places. Keep the font name
    /// consistent in `wordStyles`, `wordTheme` and the per-run properties.
    private static let wordEastAsiaFont = "PingFang SC"

    /// Word resolves eastAsia glyphs through the minor theme font when a run
    /// does not override it; a package without a theme part leaves theme-font
    /// resolution to the renderer. This theme names the same CJK family as
    /// the document defaults. The fmtScheme lists carry the DrawingML minimum
    /// cardinalities (3 fills / 3 lines / 3 effects / 3 backgrounds) so the
    /// part validates instead of being ignored by strict consumers.
    private static func wordTheme(eastAsiaFont: String) -> String {
        let ea = XMLText.escapeAttribute(eastAsiaFont)
        return #"<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Floe"><a:themeElements><a:clrScheme name="Floe"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1F497D"/></a:dk2><a:lt2><a:srgbClr val="EEECE1"/></a:lt2><a:accent1><a:srgbClr val="4F81BD"/></a:accent1><a:accent2><a:srgbClr val="C0504D"/></a:accent2><a:accent3><a:srgbClr val="9BBB59"/></a:accent3><a:accent4><a:srgbClr val="8064A2"/></a:accent4><a:accent5><a:srgbClr val="4BACC6"/></a:accent5><a:accent6><a:srgbClr val="F79646"/></a:accent6><a:hlink><a:srgbClr val="0000FF"/></a:hlink><a:folHlink><a:srgbClr val="800080"/></a:folHlink></a:clrScheme><a:fontScheme name="Floe"><a:majorFont><a:latin typeface="Arial"/><a:ea typeface="\#(ea)"/><a:cs typeface="Arial"/></a:majorFont><a:minorFont><a:latin typeface="Arial"/><a:ea typeface="\#(ea)"/><a:cs typeface="Arial"/></a:minorFont></a:fontScheme><a:fmtScheme name="Floe"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln><a:ln w="12700" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln><a:ln w="19050" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"#
    }

    /// Maps the generated title into the package core properties so Word shows
    /// the same title as the styled heading, not only as body text.
    private static func wordCoreProperties(title: String) -> String {
        #"<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>"# + XMLText.escape(title) + #"</dc:title><dc:creator>Floe</dc:creator><cp:lastModifiedBy>Floe</cp:lastModifiedBy></cp:coreProperties>"#
    }

    private static var wordStyles: String {
        let ea = XMLText.escapeAttribute(wordEastAsiaFont)
        return #"<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="\#(ea)"/><w:sz w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="\#(ea)"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="\#(ea)"/><w:b/><w:sz w:val="52"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="\#(ea)"/><w:b/><w:sz w:val="32"/></w:rPr></w:style></w:styles>"#
    }

    // MARK: - Workbook

    private static func workbookEntries(_ sheets: [OfficeWorkbookSheet]) -> [String: Data] {
        var entries: [String: Data] = [:]
        let overrides = sheets.indices.map {
            #"<Override PartName="/xl/worksheets/sheet\#($0 + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
        }.joined()
        entries["[Content_Types].xml"] = Data((xmlHeader + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>"# + overrides + "</Types>").utf8)
        entries["_rels/.rels"] = Data((xmlHeader + relationships([
            ("rId1", officeRelationship + "/officeDocument", "xl/workbook.xml")
        ])).utf8)
        entries["xl/workbook.xml"] = Data((xmlHeader + #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView/></bookViews><sheets>"# + sheets.enumerated().map { index, sheet in
            #"<sheet name="\#(XMLText.escapeAttribute(normalizedSheetName(sheet.name, index: index)))" sheetId="\#(index + 1)" r:id="rId\#(index + 1)"/>"#
        }.joined() + "</sheets><calcPr calcId=\"191029\" fullCalcOnLoad=\"1\"/></workbook>").utf8)
        entries["xl/_rels/workbook.xml.rels"] = Data((xmlHeader + relationships(
            sheets.indices.map { ("rId\($0 + 1)", officeRelationship + "/worksheet", "worksheets/sheet\($0 + 1).xml") }
                + [("rId\(sheets.count + 1)", officeRelationship + "/styles", "styles.xml")]
        )).utf8)
        entries["xl/styles.xml"] = Data((xmlHeader + workbookStyles).utf8)
        for (index, sheet) in sheets.enumerated() {
            entries["xl/worksheets/sheet\(index + 1).xml"] = Data((xmlHeader + worksheetXML(sheet.rows)).utf8)
        }
        return entries
    }

    private static func embeddedChartWorkbookData(_ chart: OfficePresentationChart) throws -> Data {
        let categories = chart.categories
        var rows: [[String]] = []
        rows.append([""] + chart.series.map(\.name))
        for (index, category) in categories.enumerated() {
            var row = [category]
            for series in chart.series {
                row.append(series.values.indices.contains(index) ? formattedNumber(series.values[index]) : "")
            }
            rows.append(row)
        }
        return try zipData(workbookEntries([OfficeWorkbookSheet(name: "Sheet1", rows: rows)]))
    }

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

    private static func formattedNumber(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    private static let workbookStyles = #"<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Arial"/></font><font><b/><color rgb="FFFFFFFF"/><sz val="11"/><name val="Arial"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF2563EB"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>"#

    // MARK: - Slide content

    private struct ObjectFrame {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    private static let layoutFrames: [OfficePresentationObject.Layout: ObjectFrame] = [
        .full: ObjectFrame(x: 685_800, y: 457_200, width: 10_820_400, height: 5_943_600),
        .left: ObjectFrame(x: 685_800, y: 1_600_200, width: 5_029_200, height: 4_114_800),
        .right: ObjectFrame(x: 6_483_600, y: 1_600_200, width: 5_029_200, height: 4_114_800),
        .top: ObjectFrame(x: 685_800, y: 457_200, width: 10_820_400, height: 2_743_200),
        .bottom: ObjectFrame(x: 685_800, y: 3_657_600, width: 10_820_400, height: 2_743_200),
        .center: ObjectFrame(x: 3_200_400, y: 2_057_400, width: 5_791_200, height: 2_743_200)
    ]

    private static func frame(for object: OfficePresentationObject, slideIndex: Int) throws -> ObjectFrame {
        let fallback = layoutFrames[object.layout ?? .center] ?? layoutFrames[.center]!
        let frame = ObjectFrame(
            x: object.x ?? fallback.x,
            y: object.y ?? fallback.y,
            width: object.width ?? fallback.width,
            height: object.height ?? fallback.height
        )
        guard frame.x >= 0, frame.y >= 0, frame.width > 0, frame.height > 0,
              frame.x + frame.width <= presentationCanvasWidth,
              frame.y + frame.height <= presentationCanvasHeight else {
            throw OfficeDocumentError.invalidContent(
                "slide \(slideIndex + 1) object geometry is outside the 16:9 canvas"
            )
        }
        return frame
    }

    private static func sanitizedColor(_ value: String?) -> String? {
        guard var hex = value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !hex.isEmpty else {
            return nil
        }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }

    private static func objectParagraphs(_ object: OfficePresentationObject, defaultColor: String) throws -> String {
        let text = object.text ?? []
        guard !text.isEmpty else {
            if object.kind == .text { throw OfficeDocumentError.invalidContent("text object has no text") }
            return #"<a:p><a:endParaRPr lang="zh-CN" sz="1800"/></a:p>"#
        }
        let size = max(100, min(20_000, Int((object.fontSize ?? 18) * 100)))
        let bold = object.bold == true ? #" b="1""# : ""
        let color = object.textColor.flatMap(sanitizedColor) ?? defaultColor
        return text.prefix(20).map { paragraph in
            #"<a:p><a:r><a:rPr lang="zh-CN" sz="\#(size)"\#(bold)><a:solidFill><a:srgbClr val="\#(color)"/></a:solidFill></a:rPr><a:t>\#(XMLText.escape(paragraph))</a:t></a:r><a:endParaRPr lang="zh-CN" sz="\#(size)"/></a:p>"#
        }.joined()
    }

    private static func textShape(
        id: Int,
        name: String,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        paragraphs: String,
        fillColor: String? = nil,
        lineColor: String? = nil
    ) -> String {
        let fill = fillColor.map { #"<a:solidFill><a:srgbClr val="\#($0)"/></a:solidFill>"# } ?? "<a:noFill/>"
        let line = lineColor.map { #"<a:ln><a:solidFill><a:srgbClr val="\#($0)"/></a:solidFill></a:ln>"# } ?? "<a:ln><a:noFill/></a:ln>"
        return #"<p:sp><p:nvSpPr><p:cNvPr id="\#(id)" name="\#(XMLText.escapeAttribute(name))"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="\#(x)" y="\#(y)"/><a:ext cx="\#(width)" cy="\#(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom>\#(fill)\#(line)</p:spPr><p:txBody><a:bodyPr wrap="square" lIns="0" tIns="0" rIns="0" bIns="0" anchor="t"/><a:lstStyle/>\#(paragraphs)</p:txBody></p:sp>"#
    }

    private static func presetShapeXML(
        id: Int,
        name: String,
        preset: String,
        frame: ObjectFrame,
        paragraphs: String,
        fillColor: String?,
        lineColor: String?
    ) -> String {
        let fill = fillColor.map { #"<a:solidFill><a:srgbClr val="\#($0)"/></a:solidFill>"# } ?? "<a:noFill/>"
        let line = lineColor.map { #"<a:ln><a:solidFill><a:srgbClr val="\#($0)"/></a:solidFill></a:ln>"# } ?? "<a:ln><a:noFill/></a:ln>"
        return #"<p:sp><p:nvSpPr><p:cNvPr id="\#(id)" name="\#(XMLText.escapeAttribute(name))"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="\#(frame.x)" y="\#(frame.y)"/><a:ext cx="\#(frame.width)" cy="\#(frame.height)"/></a:xfrm><a:prstGeom prst="\#(preset)"><a:avLst/></a:prstGeom>\#(fill)\#(line)</p:spPr><p:txBody><a:bodyPr wrap="square" anchor="ctr"/><a:lstStyle/>\#(paragraphs)</p:txBody></p:sp>"#
    }

    private static func pictureXML(id: Int, name: String, frame: ObjectFrame, relationshipID: String) -> String {
        #"<p:pic><p:nvPicPr><p:cNvPr id="\#(id)" name="\#(XMLText.escapeAttribute(name))"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="\#(relationshipID)"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x="\#(frame.x)" y="\#(frame.y)"/><a:ext cx="\#(frame.width)" cy="\#(frame.height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>"#
    }

    private static func graphicFrameXML(id: Int, name: String, frame: ObjectFrame, relationshipID: String) -> String {
        #"<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="\#(id)" name="\#(XMLText.escapeAttribute(name))"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x="\#(frame.x)" y="\#(frame.y)"/><a:ext cx="\#(frame.width)" cy="\#(frame.height)"/></p:xfrm><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart"><c:chart xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" r:id="\#(relationshipID)"/></a:graphicData></a:graphic></p:graphicFrame>"#
    }

    private enum OfficeImageFormat {
        case png
        case jpeg
        case gif

        var fileExtension: String {
            switch self {
            case .png: "png"
            case .jpeg: "jpeg"
            case .gif: "gif"
            }
        }

        var contentType: String {
            switch self {
            case .png: "image/png"
            case .jpeg: "image/jpeg"
            case .gif: "image/gif"
            }
        }

        static func detect(_ data: Data) throws -> OfficeImageFormat {
            let bytes = [UInt8](data.prefix(8))
            if bytes.count >= 8, bytes[0...7] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
                return .png
            }
            if bytes.count >= 3, bytes[0...2] == [0xFF, 0xD8, 0xFF] {
                return .jpeg
            }
            if bytes.count >= 6, Array(bytes[0...5]) == Array("GIF87a".utf8) || Array(bytes[0...5]) == Array("GIF89a".utf8) {
                return .gif
            }
            throw OfficeDocumentError.invalidContent("image must be a PNG, JPEG or GIF file")
        }
    }

    private static func imageData(for object: OfficePresentationObject) throws -> Data {
        if let base64 = object.imageBase64, !base64.isEmpty {
            guard base64.utf8.count <= maximumImageBytes * 2, let data = Data(base64Encoded: base64) else {
                throw OfficeDocumentError.invalidContent("image data is not valid base64 or is too large")
            }
            guard data.count <= maximumImageBytes else {
                throw OfficeDocumentError.invalidContent("image exceeds the 8 MiB build limit")
            }
            return data
        }
        if object.imagePath != nil {
            throw OfficeDocumentError.invalidContent(
                "imagePath must be resolved to imageBase64 by document.presentation.createDeck before building"
            )
        }
        throw OfficeDocumentError.invalidContent("image object has no image data")
    }

    private static func slideXML(_ slide: OfficePresentationSlide, deckTitle: String, additionalShapes: String = "") -> String {
        let title = slide.title.isEmpty ? deckTitle : slide.title
        let body = slide.bullets.prefix(12).enumerated().map { _, bullet in
            #"<a:p><a:pPr lvl="0" marL="342900" indent="-285750"><a:buChar char="•"/></a:pPr><a:r><a:rPr lang="zh-CN" sz="2200"/><a:t>\#(XMLText.escape(bullet))</a:t></a:r><a:endParaRPr lang="zh-CN" sz="2200"/></a:p>"#
        }.joined()
        return #"<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="F8FAFC"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\#(textShape(id: 2, name: "Title", x: 685800, y: 457200, width: 10820400, height: 1143000, paragraphs: #"<a:p><a:r><a:rPr lang="zh-CN" sz="3600" b="1"><a:solidFill><a:srgbClr val="0F172A"/></a:solidFill></a:rPr><a:t>\#(XMLText.escape(title))</a:t></a:r><a:endParaRPr lang="zh-CN" sz="3600"/></a:p>"#))\#(textShape(id: 3, name: "Content", x: 914400, y: 1905000, width: 10210800, height: 3962400, paragraphs: body.isEmpty ? #"<a:p><a:endParaRPr lang="zh-CN" sz="2200"/></a:p>"# : body))\#(additionalShapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"#
    }

    private static func notesSlideXML(_ notes: String) -> String {
        let paragraph = #"<a:p><a:r><a:rPr lang="zh-CN" sz="1200"/><a:t>\#(XMLText.escape(notes))</a:t></a:r><a:endParaRPr lang="zh-CN" sz="1200"/></a:p>"#
        return #"<p:notes xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\#(textShape(id: 2, name: "Notes", x: 685800, y: 914400, width: 5486400, height: 7315200, paragraphs: paragraph))</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>"#
    }

    // MARK: - Chart parts

    /// Standard OOXML chart part. Every series, category and value keeps a
    /// `Sheet1!$X$n` reference plus a cache, and `c:externalData` links the
    /// embedded workbook so the chart stays editable.
    private static func chartSpaceXML(_ chart: OfficePresentationChart, chartName: String) throws -> String {
        guard !chart.categories.isEmpty, chart.categories.count <= maximumChartCategories else {
            throw OfficeDocumentError.invalidContent("chart categories must contain 1...\(maximumChartCategories) entries")
        }
        guard !chart.series.isEmpty, chart.series.count <= maximumChartSeries else {
            throw OfficeDocumentError.invalidContent("chart series must contain 1...\(maximumChartSeries) entries")
        }
        for series in chart.series {
            guard series.values.count == chart.categories.count else {
                throw OfficeDocumentError.invalidContent("chart series '\(series.name)' must supply exactly one value per category")
            }
            guard series.values.allSatisfy({ $0.isFinite }) else {
                throw OfficeDocumentError.invalidContent("chart series '\(series.name)' contains a non-finite value")
            }
        }

        let lastRow = chart.categories.count + 1
        let categoryCache = zip(chart.categories, chart.categories.indices).map { category, index in
            #"<c:pt idx="\#(index)"><c:v>\#(XMLText.escape(category))</c:v></c:pt>"#
        }.joined()
        let categoryReference = "Sheet1!$A$2:$A$\(lastRow)"
        let categoryXML = #"<c:cat><c:strRef><c:f>\#(categoryReference)</c:f><c:strCache><c:ptCount val="\#(chart.categories.count)"/>\#(categoryCache)</c:strCache></c:strRef></c:cat>"#

        let seriesXML = chart.series.enumerated().map { index, series -> String in
            let column = columnName(index + 1)
            let nameReference = "Sheet1!$\(column)$1"
            let valueReference = "Sheet1!$\(column)$2:$\(column)$\(lastRow)"
            let valueCache = series.values.enumerated().map { valueIndex, value in
                #"<c:pt idx="\#(valueIndex)"><c:v>\#(formattedNumber(value))</c:v></c:pt>"#
            }.joined()
            let marker = chart.chartType == .line ? #"<c:marker><c:symbol val="none"/></c:marker>"# : ""
            return #"<c:ser><c:idx val="\#(index)"/><c:order val="\#(index)"/><c:tx><c:strRef><c:f>\#(nameReference)</c:f><c:strCache><c:ptCount val="1"/><c:pt idx="0"><c:v>\#(XMLText.escape(series.name))</c:v></c:pt></c:strCache></c:strRef></c:tx>\#(marker)\#(categoryXML)<c:val><c:numRef><c:f>\#(valueReference)</c:f><c:numCache><c:formatCode>General</c:formatCode><c:ptCount val="\#(series.values.count)"/>\#(valueCache)</c:numCache></c:numRef></c:val></c:ser>"#
        }.joined()

        let plotXML: String
        switch chart.chartType {
        case .bar:
            plotXML = #"<c:plotArea><c:layout/><c:barChart><c:barDir val="col"/><c:grouping val="clustered"/><c:varyColors val="0"/>\#(seriesXML)<c:gapWidth val="150"/><c:axId val="111111111"/><c:axId val="222222222"/></c:barChart><c:catAx><c:axId val="111111111"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="b"/><c:crossAx val="222222222"/></c:catAx><c:valAx><c:axId val="222222222"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="l"/><c:majorGridlines/><c:crossAx val="111111111"/></c:valAx></c:plotArea>"#
        case .line:
            plotXML = #"<c:plotArea><c:layout/><c:lineChart><c:grouping val="standard"/><c:varyColors val="0"/>\#(seriesXML)<c:axId val="111111111"/><c:axId val="222222222"/></c:lineChart><c:catAx><c:axId val="111111111"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="b"/><c:crossAx val="222222222"/></c:catAx><c:valAx><c:axId val="222222222"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="l"/><c:majorGridlines/><c:crossAx val="111111111"/></c:valAx></c:plotArea>"#
        case .pie:
            plotXML = #"<c:plotArea><c:layout/><c:pieChart><c:varyColors val="1"/>\#(seriesXML)<c:firstSliceAng val="0"/></c:pieChart></c:plotArea>"#
        }

        let titleXML: String
        if let chartTitle = chart.title?.trimmingCharacters(in: .whitespacesAndNewlines), !chartTitle.isEmpty {
            titleXML = #"<c:title><c:tx><c:rich><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US"/><a:t>\#(XMLText.escape(chartTitle))</a:t></a:r></a:p></c:rich></c:tx><c:overlay val="0"/></c:title>"#
        } else {
            titleXML = "<c:autoTitleDeleted val=\"1\"/>"
        }
        let legendXML = chart.chartType == .pie
            ? #"<c:legend><c:legendPos val="r"/><c:overlay val="0"/></c:legend>"#
            : #"<c:legend><c:legendPos val="b"/><c:overlay val="0"/></c:legend>"#

        return xmlHeader + #"<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><c:date1904 val="0"/><c:lang val="en-US"/><c:roundedCorners val="0"/><c:chart>\#(titleXML)\#(plotXML)\#(legendXML)<c:plotVisOnly val="1"/><c:dispBlanksAs val="gap"/></c:chart><c:externalData r:id="rId1"><c:autoUpdate val="0"/></c:externalData></c:chartSpace>"#
    }

    private static let slideLayout = #"<p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1"><p:cSld name="Blank"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"#
    private static let slideMaster = #"<p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld name="Floe"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMap accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" bg1="lt1" bg2="lt2" folHlink="folHlink" hlink="hlink" tx1="dk1" tx2="dk2"/><p:sldLayoutIdLst><p:sldLayoutId id="1" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle><a:lvl1pPr algn="l"><a:defRPr sz="3600" b="1"/></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr marL="342900" indent="-285750"><a:defRPr sz="2200"/></a:lvl1pPr></p:bodyStyle><p:otherStyle><a:defPPr><a:defRPr lang="zh-CN"/></a:defPPr></p:otherStyle></p:txStyles></p:sldMaster>"#
    private static let notesMaster = #"<p:notesMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld name="Floe Notes"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMap accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" bg1="lt1" bg2="lt2" folHlink="folHlink" hlink="hlink" tx1="dk1" tx2="dk2"/><p:notesStyle><a:lvl1pPr><a:defRPr sz="1200"/></a:lvl1pPr></p:notesStyle></p:notesMaster>"#
    private static let officeTheme = #"<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Floe"><a:themeElements><a:clrScheme name="Floe"><a:dk1><a:srgbClr val="0F172A"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="334155"/></a:dk2><a:lt2><a:srgbClr val="F8FAFC"/></a:lt2><a:accent1><a:srgbClr val="2563EB"/></a:accent1><a:accent2><a:srgbClr val="06B6D4"/></a:accent2><a:accent3><a:srgbClr val="10B981"/></a:accent3><a:accent4><a:srgbClr val="F59E0B"/></a:accent4><a:accent5><a:srgbClr val="8B5CF6"/></a:accent5><a:accent6><a:srgbClr val="EF4444"/></a:accent6><a:hlink><a:srgbClr val="2563EB"/></a:hlink><a:folHlink><a:srgbClr val="7C3AED"/></a:folHlink></a:clrScheme><a:fontScheme name="Floe"><a:majorFont><a:latin typeface="Arial"/><a:ea typeface="Source Han Sans SC"/><a:cs typeface="Arial"/></a:majorFont><a:minorFont><a:latin typeface="Arial"/><a:ea typeface="Source Han Sans SC"/><a:cs typeface="Arial"/></a:minorFont></a:fontScheme><a:fmtScheme name="Floe"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="accent1"/></a:solidFill><a:solidFill><a:schemeClr val="accent2"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="25400"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="38100"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="lt1"/></a:solidFill><a:solidFill><a:schemeClr val="lt2"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"#
}
