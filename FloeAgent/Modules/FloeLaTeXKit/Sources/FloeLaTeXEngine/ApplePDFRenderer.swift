// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import CryptoKit
import Darwin

public struct LaTeXApplePDFReceipt: Codable, Sendable {
    public let pageCount: Int
    public let bytes: Int
    public let sha256: String
    public let fontCount: Int
    public let glyphCount: Int
    public let legacyGlyphCount: Int
    public let imageCount: Int
    public let pdfImportCount: Int
    public let consumedSpecials: Int
    public var navigation: LaTeXApplePDFNavigationReceipt? = nil
}

public struct LaTeXLegacyOutlineSegment: Sendable {
    public let kind: Int32
    public let x1: Double, y1: Double, x2: Double, y2: Double, x3: Double, y3: Double
    public init(kind: Int32, x1: Double = 0, y1: Double = 0, x2: Double = 0, y2: Double = 0, x3: Double = 0, y3: Double = 0) {
        self.kind=kind; self.x1=x1; self.y1=y1; self.x2=x2; self.y2=y2; self.x3=x3; self.y3=y3
    }
}
public struct LaTeXLegacyGlyphOutline: Sendable {
    public let unitsPerEm: Double
    public let segments: [LaTeXLegacyOutlineSegment]
    public init(unitsPerEm: Double, segments: [LaTeXLegacyOutlineSegment]) { self.unitsPerEm=unitsPerEm; self.segments=segments }
}
public typealias LaTeXLegacyGlyphOutlineProvider = @Sendable (Data, UInt32, String?, Int32) throws -> LaTeXLegacyGlyphOutline

public struct LaTeXAppleFontProbe: Codable, Sendable {
    public let coreGraphicsFontLoaded: Bool
    public let coreTextDescriptorCount: Int
}

public enum LaTeXApplePDFError: Error, LocalizedError, Sendable {
    case invalidDisplayList
    case limit(String)
    case unsafePath
    case invalidFont(Int32)
    case unsupportedFontFace(Int32)
    case unsupportedSpecial(String)
    case invalidResource(String)
    case unbalancedState
    case outputExists
    case outputFailure
    public var errorDescription: String? {
        switch self {
        case .invalidDisplayList: "The native typesetter returned an invalid display list."
        case .limit(let kind): "The native PDF exceeds its \(kind) limit."
        case .unsafePath: "A native typesetting resource is outside its authorized roots or uses a symbolic link."
        case .invalidFont(let id): "The native font \(id) could not be loaded exactly."
        case .unsupportedFontFace(let id): "The exact face of native font \(id) could not be identified."
        case .unsupportedSpecial(let kind): "This document requires an unsupported native typesetting special: \(kind)."
        case .invalidResource(let kind): "The native \(kind) resource could not be decoded."
        case .unbalancedState: "The native document has unbalanced graphics or color state."
        case .outputExists: "The native PDF destination already exists; its previous bytes were retained."
        case .outputFailure: "The native PDF could not be completed and published."
        }
    }
}

/// Consumes real native-font glyph IDs and positions, never substitutes a
/// text layout engine. App callers execute this synchronous operation through
/// their existing PDFKitGate + withPDFExceptionGuard boundary. No PDFKit API,
/// subprocess, Linux interpreter, network or executable plugin is used here.
public enum LaTeXApplePDFRenderer {
    public static func render(displayListData: Data, allowedRoots: [URL], outputURL: URL,
                              legacyOutlineProvider: LaTeXLegacyGlyphOutlineProvider? = nil,
                              cancellation: @escaping @Sendable () -> Bool = { false }) throws -> LaTeXApplePDFReceipt {
        try Renderer(data: displayListData, roots: allowedRoots, output: outputURL, legacy: legacyOutlineProvider, cancelled: cancellation).render()
    }
    /// Qualification of exact font bytes on the actual target; the renderer
    /// never assumes a PFB that loads on macOS also loads on iOS.
    public static func probeFont(data: Data) throws -> LaTeXAppleFontProbe {
        guard !data.isEmpty, data.count <= 64*1024*1024 else { throw LaTeXApplePDFError.limit("font bytes") }
        let provider = CGDataProvider(data: data as CFData)
        let graphics = provider.flatMap { CGFont($0) } != nil
        let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor]
        return LaTeXAppleFontProbe(coreGraphicsFontLoaded: graphics, coreTextDescriptorCount: descriptors?.count ?? 0)
    }
}

private struct AppleDisplayList: Decodable {
    let `protocol`: String
    let version: Int
    let units: String
    let origin: String
    let fonts: [AppleFont]
    let assets: [AppleAsset]?
    let pages: [ApplePage]
}
private struct AppleFont: Decodable {
    let id: Int32
    let path: String?
    let name: String
    let size: Double
    let faceIndex: UInt32
    let postScriptName: String?
    let extend: Double?
    let slant: Double?
    let embolden: Double?
    let colorRGBA: UInt32?
    let kind: String?
    let encodingPath: String?
    let encoding: String?
}
private struct AppleAsset: Decodable { let name: String; let path: String; let kind: String }
private struct ApplePage: Decodable { let width: Double; let height: Double; let ops: [AppleOperation] }
private struct AppleOperation: Decodable {
    let kind: String
    let fontID: Int32?
    let glyphs: [UInt16]?
    let x: AppleCoordinate?
    let y: AppleCoordinate?
    let width: Double?
    let height: Double?
    let dataBase64: String?
    let path: String?
    let page: Int?
    let box: String?
    let transform: [Double]?
    let character: Int32?
    let glyphName: String?
    var scalarX: Double? { if case .scalar(let n) = x { n } else { nil } }
    var scalarY: Double? { if case .scalar(let n) = y { n } else { nil } }
}
private enum AppleCoordinate: Decodable {
    case scalar(Double), array([Double])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let values = try? c.decode([Double].self) { self = .array(values) }
        else { self = .scalar(try c.decode(Double.self)) }
    }
}
private struct AppleColor {
    let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
    private let cmyk: [CGFloat]?
    static let black = AppleColor(r: 0, g: 0, b: 0, a: 1)
    var cg: CGColor {
        if let cmyk {
            // Keep the actual DeviceCMYK components in the PDF. Converting
            // with a hand-written RGB formula loses the source color space.
            return CGColor(colorSpace: CGColorSpaceCreateDeviceCMYK(), components: cmyk)!
        }
        return CGColor(red: r, green: g, blue: b, alpha: a)
    }
    init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) { self.r=r; self.g=g; self.b=b; self.a=a; cmyk=nil }
    init(cmyk: [CGFloat]) { r=0; g=0; b=0; a=1; self.cmyk=cmyk+[1] }
    init(packed: UInt32) {
        r = CGFloat((packed >> 24) & 255)/255; g = CGFloat((packed >> 16) & 255)/255
        b = CGFloat((packed >> 8) & 255)/255; a = CGFloat(packed & 255)/255
        cmyk = nil
    }
}

private final class Renderer {
    private static let fileLimit = 64 * 1024 * 1024
    private static let outputLimit = 256 * 1024 * 1024
    private let list: AppleDisplayList
    private let roots: [URL]
    private let output: URL
    private let cancelled: @Sendable () -> Bool
    private let legacy: LaTeXLegacyGlyphOutlineProvider?
    private var fonts: [Int32: (CTFont?, AppleFont)] = [:]
    private var legacyData: [Int32: Data] = [:]
    private var legacyPaths: [String: CGPath] = [:]
    private var legacySegmentCount = 0
    private var assets: [String: AppleAsset] = [:]
    private var glyphCount = 0, imageCount = 0, pdfCount = 0, specialCount = 0
    private var legacyGlyphCount = 0
    private var totalOperations = 0
    private var navigation: NativePDFDocumentSemantics?
    private let started = ProcessInfo.processInfo.systemUptime

    init(data: Data, roots: [URL], output: URL, legacy: LaTeXLegacyGlyphOutlineProvider?, cancelled: @escaping @Sendable () -> Bool) throws {
        guard data.count <= 64*1024*1024 else { throw LaTeXApplePDFError.limit("display-list bytes") }
        list = try JSONDecoder().decode(AppleDisplayList.self, from: data)
        guard list.protocol == "floe.tex.display-list", list.version == 1, list.units == "bp", list.origin == "top-left",
              !list.pages.isEmpty, list.pages.count <= 2000, list.fonts.count <= 1024,
              (list.assets?.count ?? 0) <= 4096, !roots.isEmpty, roots.count <= 32 else { throw LaTeXApplePDFError.invalidDisplayList }
        self.roots = try roots.map { u in
            let n = u.standardizedFileURL
            guard n.isFileURL, n.path == n.resolvingSymlinksInPath().path,
                  (try n.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw LaTeXApplePDFError.unsafePath }
            return n
        }
        self.output = output.standardizedFileURL; self.cancelled = cancelled; self.legacy = legacy
        guard self.output.isFileURL, self.output.path.utf8.count <= 4096,
              !self.output.lastPathComponent.isEmpty,
              self.roots.contains(where: { Self.inside(self.output, $0) }),
              self.output.deletingLastPathComponent().path == self.output.deletingLastPathComponent().resolvingSymlinksInPath().path else { throw LaTeXApplePDFError.unsafePath }
        for asset in list.assets ?? [] {
            guard asset.name.utf8.count <= 4096, !asset.name.isEmpty, assets[asset.name] == nil,
                  ["font", "image", "pdf"].contains(asset.kind) else { throw LaTeXApplePDFError.invalidDisplayList }
            assets[asset.name] = asset
        }
    }
    private func check() throws {
        if cancelled() || Task.isCancelled { throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime-started > 120 { throw LaTeXApplePDFError.limit("render time") }
    }
    private static func inside(_ file: URL, _ root: URL) -> Bool { file.path.hasPrefix(root.path + "/") }
    private func number(_ n: Double?, positive: Bool = false) throws -> CGFloat {
        guard let n, n.isFinite, abs(n) <= 1_000_000, !positive || n > 0 else { throw LaTeXApplePDFError.invalidDisplayList }
        return CGFloat(n)
    }
    /// openat walks each component under an already authorized root. Rejects
    /// symlinks at every level, including a replaced final component.
    private func read(_ path: String) throws -> Data {
        try check()
        guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\0") else { throw LaTeXApplePDFError.unsafePath }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL : roots[0].appendingPathComponent(path).standardizedFileURL
        guard let root = roots.filter({ Self.inside(url, $0) }).max(by: { $0.path.count < $1.path.count }) else { throw LaTeXApplePDFError.unsafePath }
        let components = String(url.path.dropFirst(root.path.count + 1)).split(separator: "/").map(String.init)
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else { throw LaTeXApplePDFError.unsafePath }
        var fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LaTeXApplePDFError.unsafePath }
        defer { Darwin.close(fd) }
        for component in components.dropLast() {
            let next = Darwin.openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw LaTeXApplePDFError.unsafePath }
            Darwin.close(fd); fd = next
        }
        let file = Darwin.openat(fd, components.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw LaTeXApplePDFError.unsafePath }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= Self.fileLimit else { throw LaTeXApplePDFError.limit("resource bytes") }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        result.reserveCapacity(Int(info.st_size))
        while true {
            try check()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress!, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw LaTeXApplePDFError.invalidResource("file") }
            if count == 0 { break }
            guard result.count <= Self.fileLimit-count else { throw LaTeXApplePDFError.limit("resource bytes") }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
    private func loadFonts() throws {
        for spec in list.fonts {
            try check()
            guard fonts[spec.id] == nil, spec.size.isFinite, spec.size > 0, spec.size <= 4096,
                  spec.name.utf8.count <= 4096 else { throw LaTeXApplePDFError.invalidFont(spec.id) }
            let extend = spec.extend ?? 1, slant = spec.slant ?? 0, bold = spec.embolden ?? 0
            guard extend.isFinite, extend > 0, extend <= 16, slant.isFinite, abs(slant) <= 16,
                  bold.isFinite, bold >= 0, bold <= 100 else { throw LaTeXApplePDFError.invalidFont(spec.id) }
            if spec.kind == "legacy" {
                guard legacy != nil, let path = spec.path else { throw LaTeXApplePDFError.invalidFont(spec.id) }
                let data = try read(path)
                guard legacyData.values.reduce(0, { $0+$1.count }) <= 128*1024*1024-data.count else { throw LaTeXApplePDFError.limit("legacy font bytes") }
                legacyData[spec.id] = data; fonts[spec.id] = (nil, spec)
                if let path = spec.encodingPath { _ = try read(path) }
                continue
            }
            var matrix = CGAffineTransform(a: extend, b: 0, c: slant, d: 1, tx: 0, ty: 0)
            let font: CTFont
            if let path = spec.path {
                let data = try read(path)
                guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor], !descriptors.isEmpty else { throw LaTeXApplePDFError.invalidFont(spec.id) }
                let selected: CTFontDescriptor
                if let ps = spec.postScriptName {
                    let matches = descriptors.filter { (CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String) == ps }
                    guard matches.count == 1 else { throw LaTeXApplePDFError.unsupportedFontFace(spec.id) }
                    selected = matches[0]
                } else {
                    guard descriptors.count == 1, spec.faceIndex == 0 else { throw LaTeXApplePDFError.unsupportedFontFace(spec.id) }
                    selected = descriptors[0]
                }
                font = CTFontCreateWithFontDescriptor(selected, spec.size, &matrix)
            } else {
                let ps = spec.postScriptName ?? spec.name
                guard spec.faceIndex == 0, ps.utf8.count <= 256 else { throw LaTeXApplePDFError.unsupportedFontFace(spec.id) }
                font = CTFontCreateWithName(ps as CFString, spec.size, &matrix)
                guard CTFontCopyPostScriptName(font) as String == ps else { throw LaTeXApplePDFError.invalidFont(spec.id) }
            }
            if let expected = spec.postScriptName, CTFontCopyPostScriptName(font) as String != expected { throw LaTeXApplePDFError.unsupportedFontFace(spec.id) }
            guard CTFontGetGlyphCount(font) > 0 else { throw LaTeXApplePDFError.invalidFont(spec.id) }
            fonts[spec.id] = (font, spec)
        }
    }
    private func navigationPlan() throws -> NativePDFDocumentSemantics {
        let plan = NativePDFDocumentSemantics(pages: list.pages.count, check: { [unowned self] in try self.check() })
        for (pageIndex, page) in list.pages.enumerated() {
            let height = try number(page.height, positive: true)
            for (index, op) in page.ops.enumerated() where op.kind == "special" {
                let x = try number(op.scalarX), y = try number(op.scalarY)
                try plan.record(try special(op), key: NativePDFDocumentSemantics.key(pageIndex,index),
                    page: pageIndex, point: CGPoint(x:x,y:height-y))
            }
        }
        try plan.validateReferences(); return plan
    }
    private func ink(_ value: NativePDFInk?) -> AppleColor {
        guard let value else { return .black }
        switch value.model {
        case "g": return AppleColor(r:value.components[0],g:value.components[0],b:value.components[0],a:1)
        case "rg": return AppleColor(r:value.components[0],g:value.components[1],b:value.components[2],a:1)
        default: return AppleColor(cmyk:value.components.map { CGFloat($0) })
        }
    }
    func render() throws -> LaTeXApplePDFReceipt {
        try check(); try loadFonts()
        let navigation = try navigationPlan(); self.navigation = navigation
        guard !FileManager.default.fileExists(atPath: output.path) else { throw LaTeXApplePDFError.outputExists }
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".floe-native-partial-" + UUID().uuidString + ".pdf")
        // Failed owned partial output remains available for diagnosis; it is
        // never substituted for an existing or completed PDF.
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LaTeXApplePDFError.outputFailure }
        let sink = PDFSink(fd: fd, limit: Self.outputLimit, cancelled: cancelled)
        defer { sink.close() }
        let retained = Unmanaged.passRetained(sink)
        var callbacks = CGDataConsumerCallbacks(putBytes: { opaque, bytes, count in
            guard let opaque else { return 0 }
            return Unmanaged<PDFSink>.fromOpaque(opaque).takeUnretainedValue().put(bytes, count)
        }, releaseConsumer: { opaque in
            if let opaque { Unmanaged<PDFSink>.fromOpaque(opaque).release() }
        })
        guard let consumer = CGDataConsumer(info: retained.toOpaque(), cbks: &callbacks) else {
            retained.release(); throw LaTeXApplePDFError.outputFailure
        }
        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &defaultBox,
            navigation.auxiliaryInfo as CFDictionary) else { throw LaTeXApplePDFError.outputFailure }
        var closed = false
        defer { if !closed { context.closePDF() } }
        for (pageIndex, page) in list.pages.enumerated() {
            try check()
            let width = try number(page.width, positive: true), height = try number(page.height, positive: true)
            guard width <= 100_000, height <= 100_000, page.ops.count <= 1_000_000 else { throw LaTeXApplePDFError.limit("page geometry/operations") }
            totalOperations += page.ops.count
            guard totalOperations <= 2_000_000 else { throw LaTeXApplePDFError.limit("operations") }
            var box = CGRect(x: 0, y: 0, width: width, height: height)
            let pageInfo = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(pageInfo)
            context.textMatrix = CGAffineTransform.identity
            var color = ink(navigation.pageInk), colors = [AppleColor]()
            for (operationIndex, op) in page.ops.enumerated() {
                try check()
                switch op.kind {
                case "glyphRun":
                    guard let id = op.fontID, let entry = fonts[id], let font = entry.0, let glyphs = op.glyphs,
                          let xValues = op.x, let yValues = op.y,
                          case .array(let xs) = xValues, case .array(let ys) = yValues,
                          !glyphs.isEmpty, glyphs.count == xs.count, xs.count == ys.count,
                          glyphs.count <= 65536 else { throw LaTeXApplePDFError.invalidDisplayList }
                    glyphCount += glyphs.count
                    guard glyphCount <= 2_000_000 else { throw LaTeXApplePDFError.limit("glyphs") }
                    let spec = entry.1
                    let positions = try zip(xs, ys).map { pair in
                        let x = try number(pair.0), y = try number(pair.1)
                        return CGPoint(x: x, y: height-y)
                    }
                    guard glyphs.allSatisfy({ Int($0) < CTFontGetGlyphCount(font) }) else { throw LaTeXApplePDFError.invalidFont(id) }
                    context.saveGState()
                    let ink = spec.colorRGBA.map(AppleColor.init(packed:)) ?? color
                    context.setFillColor(ink.cg); context.setStrokeColor(ink.cg)
                    let bold = spec.embolden ?? 0
                    context.setTextDrawingMode(bold > 0 ? .fillStroke : .fill)
                    if bold > 0 { context.setLineWidth(bold) }
                    if navigation.isAnnotationActive {
                        var bounds = [CGRect](repeating:.zero,count:glyphs.count)
                        CTFontGetBoundingRectsForGlyphs(font,.horizontal,glyphs,&bounds,glyphs.count)
                        for (index, rect) in bounds.enumerated() {
                            try navigation.includeInk(rect.insetBy(dx:-bold/2,dy:-bold/2)
                                .offsetBy(dx:positions[index].x,dy:positions[index].y))
                        }
                    }
                    CTFontDrawGlyphs(font, glyphs, positions, glyphs.count, context)
                    context.restoreGState()
                case "legacyGlyph":
                    try drawLegacy(op, pageHeight: height, color: color, context: context)
                case "rule":
                    let x = try number(op.scalarX), y = try number(op.scalarY)
                    let w = try number(op.width), h = try number(op.height)
                    // DVI non-positive rules are defined to paint nothing.
                    if w > 0 && h > 0 {
                        let rect = CGRect(x:x,y:height-y-h,width:w,height:h)
                        try navigation.includeInk(rect); context.setFillColor(color.cg); context.fill(rect)
                    }
                case "image", "pdf":
                    let data = try read(try required(op.path))
                    let x = try number(op.scalarX), y = try number(op.scalarY), w = try number(op.width, positive: true), h = try number(op.height, positive: true)
                    context.saveGState()
                    context.translateBy(x: x, y: height-y-h)
                    if let matrix = op.transform { context.concatenate(try affine(matrix)) }
                    if op.kind == "pdf" { try drawPDF(data, page: op.page ?? 1, box: op.box ?? "crop", rect: CGRect(x: 0, y: 0, width: w, height: h), context: context) }
                    else { try drawRaster(data, rect: CGRect(x: 0, y: 0, width: w, height: h), context: context) }
                    context.restoreGState()
                case "special":
                    if let command = navigation.commands[NativePDFDocumentSemantics.key(pageIndex,operationIndex)] {
                        if let value = try navigation.perform(command,page:pageIndex) { color = ink(value) }
                    } else {
                        let text = try special(op)
                        try applySpecial(text, operation: op, pageWidth: width, pageHeight: height,
                                         context: context, color: &color, colors: &colors)
                    }
                    specialCount += 1
                default: throw LaTeXApplePDFError.unsupportedSpecial("operation")
                }
            }
            guard colors.isEmpty else { throw LaTeXApplePDFError.unbalancedState }
            try navigation.endPage(); context.endPDFPage()
        }
        context.closePDF(); closed = true
        if let failure = sink.failure { throw failure }
        try check()
        guard fsync(fd) == 0 else { throw LaTeXApplePDFError.outputFailure }
        let original = try Data(contentsOf: temporary, options: [.mappedIfSafe])
        let (revision, header, navigationReceipt) = try navigation.revision(original)
        if let header {
            try check()
            let written = header.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.pwrite(fd,base,buffer.count,0)
            }
            guard written == header.count else { throw LaTeXApplePDFError.outputFailure }
        }
        if !revision.isEmpty {
            try check()
            let written = revision.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return sink.put(base,buffer.count)
            }
            guard written == revision.count else { throw sink.failure ?? LaTeXApplePDFError.outputFailure }
        }
        try check(); guard fsync(fd) == 0 else { throw LaTeXApplePDFError.outputFailure }
        sink.close()
        let pdf = try Data(contentsOf: temporary, options: [.mappedIfSafe])
        guard !pdf.isEmpty, pdf.count <= Self.outputLimit, pdf.starts(with: Data("%PDF-".utf8)),
              let provider = CGDataProvider(data: pdf as CFData), let verified = CGPDFDocument(provider),
              verified.numberOfPages == list.pages.count else { throw LaTeXApplePDFError.outputFailure }
        try navigation.validate(verified)
        try check()
        guard output.deletingLastPathComponent().path == output.deletingLastPathComponent().resolvingSymlinksInPath().path else { throw LaTeXApplePDFError.unsafePath }
        // link is an atomic no-replace publication on this same filesystem.
        // Existing outputs are never overwritten by a race between checks.
        let linked = temporary.path.withCString { a in output.path.withCString { b in Darwin.link(a, b) } }
        guard linked == 0 else { throw errno == EEXIST ? LaTeXApplePDFError.outputExists : LaTeXApplePDFError.outputFailure }
        _ = Darwin.unlink(temporary.path)
        return LaTeXApplePDFReceipt(pageCount: list.pages.count, bytes: pdf.count,
            sha256: SHA256.hash(data: pdf).map { String(format: "%02x", $0) }.joined(), fontCount: fonts.count,
            glyphCount: glyphCount, legacyGlyphCount: legacyGlyphCount, imageCount: imageCount, pdfImportCount: pdfCount, consumedSpecials: specialCount,
            navigation: navigationReceipt)
    }
    private func required(_ value: String?) throws -> String {
        guard let value, !value.isEmpty else { throw LaTeXApplePDFError.invalidDisplayList }; return value
    }
    private func drawLegacy(_ op: AppleOperation, pageHeight: CGFloat, color: AppleColor, context: CGContext) throws {
        guard let id = op.fontID, let entry = fonts[id], entry.1.kind == "legacy",
              let data = legacyData[id], let legacy, let character = op.character,
              (0...255).contains(character) else { throw LaTeXApplePDFError.invalidDisplayList }
        let spec = entry.1
        if spec.encodingPath != nil && op.glyphName == nil { throw LaTeXApplePDFError.unsupportedFontFace(id) }
        if let name = op.glyphName {
            guard !name.isEmpty, name.utf8.count <= 256, name.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw LaTeXApplePDFError.invalidFont(id) }
        }
        let key = String(id) + ":" + (op.glyphName.map { "name:"+$0 } ?? "char:"+String(character))
        let path: CGPath
        if let cached = legacyPaths[key] { path = cached }
        else {
            try check()
            let outline = try legacy(data, spec.faceIndex, op.glyphName, character)
            guard outline.unitsPerEm.isFinite, outline.unitsPerEm > 0, outline.unitsPerEm <= 65536,
                  outline.segments.count <= 65536, legacyPaths.count < 8192 else { throw LaTeXApplePDFError.limit("legacy glyph outline") }
            legacySegmentCount += outline.segments.count
            guard legacySegmentCount <= 2_000_000 else { throw LaTeXApplePDFError.limit("legacy outline segments") }
            let shape = CGMutablePath()
            var contour = false
            for segment in outline.segments {
                try check()
                let values = [segment.x1, segment.y1, segment.x2, segment.y2, segment.x3, segment.y3]
                guard values.allSatisfy({ $0.isFinite && abs($0) <= 10_000_000 }) else { throw LaTeXApplePDFError.invalidFont(id) }
                switch segment.kind {
                case 0:
                    guard !contour else { throw LaTeXApplePDFError.invalidFont(id) }
                    shape.move(to: CGPoint(x: segment.x1, y: segment.y1)); contour = true
                case 1:
                    guard contour else { throw LaTeXApplePDFError.invalidFont(id) }
                    shape.addLine(to: CGPoint(x: segment.x1, y: segment.y1))
                case 2:
                    guard contour else { throw LaTeXApplePDFError.invalidFont(id) }
                    shape.addQuadCurve(to: CGPoint(x: segment.x2, y: segment.y2), control: CGPoint(x: segment.x1, y: segment.y1))
                case 3:
                    guard contour else { throw LaTeXApplePDFError.invalidFont(id) }
                    shape.addCurve(to: CGPoint(x: segment.x3, y: segment.y3),
                        control1: CGPoint(x: segment.x1, y: segment.y1), control2: CGPoint(x: segment.x2, y: segment.y2))
                case 4:
                    guard contour else { throw LaTeXApplePDFError.invalidFont(id) }
                    shape.closeSubpath(); contour = false
                default: throw LaTeXApplePDFError.invalidFont(id)
                }
            }
            guard !contour else { throw LaTeXApplePDFError.invalidFont(id) }
            let scale = spec.size / outline.unitsPerEm
            var transform = CGAffineTransform(a: scale*(spec.extend ?? 1), b: 0, c: scale*(spec.slant ?? 0), d: scale, tx: 0, ty: 0)
            guard let transformed = shape.copy(using: &transform) else { throw LaTeXApplePDFError.invalidFont(id) }
            path = transformed; legacyPaths[key] = path
        }
        glyphCount += 1
        legacyGlyphCount += 1
        guard glyphCount <= 2_000_000 else { throw LaTeXApplePDFError.limit("glyphs") }
        let x = try number(op.scalarX), y = try number(op.scalarY)
        let ink = spec.colorRGBA.map(AppleColor.init(packed:)) ?? color
        context.saveGState(); context.translateBy(x: x, y: pageHeight-y)
        context.setFillColor(ink.cg); context.setStrokeColor(ink.cg); context.addPath(path)
        let bold = spec.embolden ?? 0
        try navigation?.includeInk(path.boundingBoxOfPath.insetBy(dx:-bold/2,dy:-bold/2)
            .offsetBy(dx:x,dy:pageHeight-y))
        if bold > 0 { context.setLineWidth(bold); context.drawPath(using: .fillStroke) }
        else { context.fillPath() }
        context.restoreGState()
    }
    private func affine(_ values: [Double]) throws -> CGAffineTransform {
        guard values.count == 6 else { throw LaTeXApplePDFError.invalidDisplayList }
        let n = try values.map { try number($0) }
        guard abs(n[0]*n[3]-n[1]*n[2]) > 0.000000000001 else { throw LaTeXApplePDFError.invalidDisplayList }
        return CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
    }
    private func drawRaster(_ data: Data, rect: CGRect, context: CGContext) throws {
        try check()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (info[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (info[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0, width <= 32768, height <= 32768, width*height <= 16_777_216 else { throw LaTeXApplePDFError.invalidResource("image") }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height)] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { throw LaTeXApplePDFError.invalidResource("image") }
        try navigation?.includeInk(rect.applying(context.ctm))
        context.interpolationQuality = .high; context.draw(image, in: rect)
        imageCount += 1; try check()
    }
    private func drawPDF(_ data: Data, page requested: Int, box name: String, rect: CGRect, context: CGContext) throws {
        try check()
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider),
              !doc.isEncrypted || doc.isUnlocked, doc.numberOfPages > 0, doc.numberOfPages <= 10000 else { throw LaTeXApplePDFError.invalidResource("PDF") }
        let index = requested == 0 ? 1 : requested < 0 ? doc.numberOfPages + requested + 1 : requested
        guard index > 0, index <= doc.numberOfPages, let page = doc.page(at: index) else { throw LaTeXApplePDFError.invalidResource("PDF page") }
        let box = try pdfBox(name)
        let bounds = page.getBoxRect(box)
        guard !bounds.isNull, !bounds.isInfinite, bounds.width > 0, bounds.height > 0,
              bounds.width <= 100000, bounds.height <= 100000 else { throw LaTeXApplePDFError.invalidResource("PDF page box") }
        try navigation?.includeInk(rect.applying(context.ctm))
        context.saveGState(); context.clip(to: rect)
        context.concatenate(page.getDrawingTransform(box, rect: rect, rotate: 0, preserveAspectRatio: false))
        context.drawPDFPage(page); context.restoreGState()
        pdfCount += 1; try check()
    }
    private func pdfBox(_ value: String) throws -> CGPDFBox {
        switch value {
        case "crop", "cropbox": .cropBox
        case "media", "mediabox": .mediaBox
        case "bleed", "bleedbox": .bleedBox
        case "trim", "trimbox": .trimBox
        case "art", "artbox": .artBox
        default: throw LaTeXApplePDFError.invalidResource("PDF box")
        }
    }
    private func rotatedBox(_ page: CGPDFPage, _ box: CGPDFBox) throws -> CGRect {
        let rotation = page.rotationAngle % 360
        guard rotation % 90 == 0 else { throw LaTeXApplePDFError.invalidResource("PDF rotation") }
        let source = page.getBoxRect(box)
        let result = source.applying(CGAffineTransform(rotationAngle: -CGFloat(rotation) * CGFloat.pi / 180))
        guard !result.isNull, !result.isInfinite, result.width > 0, result.height > 0,
              result.width <= 100000, result.height <= 100000,
              result.origin.x.isFinite, result.origin.y.isFinite else { throw LaTeXApplePDFError.invalidResource("PDF page box") }
        return result
    }
    private func special(_ op: AppleOperation) throws -> String {
        guard let encoded = op.dataBase64, encoded.utf8.count <= 65536,
              let data = Data(base64Encoded: encoded), data.count <= 32768,
              let text = String(data: data, encoding: .utf8) else { throw LaTeXApplePDFError.unsupportedSpecial("binary") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applySpecial(_ text: String, operation: AppleOperation, pageWidth: CGFloat, pageHeight: CGFloat,
                              context: CGContext, color: inout AppleColor, colors: inout [AppleColor]) throws {
        let lexer = SpecialTokens(text)
        let tokens = try lexer.all()
        if tokens == ["color", "pop"] || tokens == ["pdf:ec"] {
            guard let old = colors.popLast() else { throw LaTeXApplePDFError.unbalancedState }; color = old; return
        }
        if tokens.starts(with: ["color", "push"]) {
            guard colors.count < 64 else { throw LaTeXApplePDFError.limit("color stack") }
            let next = try parseColor(Array(tokens.dropFirst(2))); colors.append(color); color = next; return
        }
        if tokens.first == "color" { color = try parseColor(Array(tokens.dropFirst())); return }
        if tokens.first == "pdf:bc" {
            let values = tokens.dropFirst().filter { $0 != "[" && $0 != "]" }
            let model = values.count == 1 ? "gray" : values.count == 3 ? "rgb" : values.count == 4 ? "cmyk" : "invalid"
            guard colors.count < 64 else { throw LaTeXApplePDFError.limit("color stack") }
            colors.append(color); color = try parseColor([model] + values); return
        }
        if text.hasPrefix("papersize=") {
            let values = text.dropFirst("papersize=".count).split(separator: ",").map(String.init)
            guard values.count == 2, abs(try dimension(values[0])-pageWidth) < 0.1,
                  abs(try dimension(values[1])-pageHeight) < 0.1 else { throw LaTeXApplePDFError.invalidDisplayList }; return
        }
        if tokens.first == "pdf:pagesize" {
            guard tokens.count == 5, tokens[1] == "width", tokens[3] == "height",
                  abs(try dimension(tokens[2])-pageWidth) < 0.1, abs(try dimension(tokens[4])-pageHeight) < 0.1 else { throw LaTeXApplePDFError.invalidDisplayList }; return
        }
        if tokens.starts(with: ["pdf:image", "matrix"]) {
            try imageSpecial(tokens, operation: operation, pageHeight: pageHeight, context: context); return
        }
        // Every unimplemented special is a visible capability failure. In
        // particular, PostScript/PDF literal graphics, annotations, document
        // dictionaries, links and background changes are never discarded.
        let kind = String((tokens.first ?? "empty").prefix(48)).filter { $0.isASCII && ($0.isLetter || $0.isNumber || ":_-".contains($0)) }
        throw LaTeXApplePDFError.unsupportedSpecial(kind.isEmpty ? "unknown" : kind)
    }
    private func parseColor(_ values: [String]) throws -> AppleColor {
        guard let model = values.first else { throw LaTeXApplePDFError.invalidDisplayList }
        let n = try values.dropFirst().map { s -> CGFloat in
            guard let d = Double(s), d.isFinite, (0...1).contains(d) else { throw LaTeXApplePDFError.invalidDisplayList }; return CGFloat(d)
        }
        switch model {
        case "rgb" where n.count == 3: return AppleColor(r: n[0], g: n[1], b: n[2], a: 1)
        case "gray" where n.count == 1: return AppleColor(r: n[0], g: n[0], b: n[0], a: 1)
        case "cmyk" where n.count == 4: return AppleColor(cmyk: n)
        default: throw LaTeXApplePDFError.unsupportedSpecial("color-model")
        }
    }
    private func dimension(_ raw: String) throws -> CGFloat {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let units: [(String, Double)] = [("bp",1),("pt",72/72.27),("in",72),("cm",72/2.54),("mm",72/25.4)]
        for (unit, factor) in units where s.hasSuffix(unit) {
            guard let value = Double(s.dropLast(unit.count)) else { throw LaTeXApplePDFError.invalidDisplayList }
            return try number(value*factor, positive: true)
        }
        throw LaTeXApplePDFError.unsupportedSpecial("page-units")
    }
    private func imageSpecial(_ tokens: [String], operation: AppleOperation, pageHeight: CGFloat, context: CGContext) throws {
        guard tokens.count >= 11 else { throw LaTeXApplePDFError.invalidDisplayList }
        let values = try tokens[2..<8].map { value -> Double in
            guard let n = Double(value), n.isFinite else { throw LaTeXApplePDFError.invalidDisplayList }; return n
        }
        var position = 8, requested = 1, box = "crop"
        guard tokens[position] == "page", let page = Int(tokens[position+1]) else { throw LaTeXApplePDFError.invalidDisplayList }
        requested = page; position += 2
        if tokens[position] == "pagebox" {
            guard position+1 < tokens.count else { throw LaTeXApplePDFError.invalidDisplayList }
            box = tokens[position+1]; position += 2
        }
        guard position == tokens.count-1, tokens[position].hasPrefix("(") else { throw LaTeXApplePDFError.invalidDisplayList }
        let name = String(tokens[position].dropFirst().dropLast())
        guard let asset = assets[name], asset.kind == "image" || asset.kind == "pdf" else { throw LaTeXApplePDFError.invalidResource("image alias") }
        let data = try read(asset.path), matrix = try affine(values)
        let x = try number(operation.scalarX), y = try number(operation.scalarY)
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: x, y: pageHeight-y); context.concatenate(matrix)
        if data.starts(with: Data("%PDF-".utf8)) {
            guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
                  !document.isEncrypted || document.isUnlocked else { throw LaTeXApplePDFError.invalidResource("PDF") }
            let index = requested == 0 ? 1 : requested < 0 ? document.numberOfPages + requested + 1 : requested
            guard index > 0, index <= document.numberOfPages, let page = document.page(at: index) else { throw LaTeXApplePDFError.invalidResource("PDF page") }
            let area = try rotatedBox(page, pdfBox(box))
            try drawPDF(data, page: requested, box: box, rect: area, context: context)
        } else {
            guard requested == 0 || requested == 1, let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let px = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
                  let py = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { throw LaTeXApplePDFError.invalidResource("image") }
            let dx = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
            let dy = (properties[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue ?? 72
            guard dx.isFinite, dy.isFinite, dx > 0, dy > 0 else { throw LaTeXApplePDFError.invalidResource("image DPI") }
            var width = px*72/dx, height = py*72/dy
            if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(orientation) { swap(&width, &height) }
            try drawRaster(data, rect: CGRect(x: 0, y: 0, width: try number(width, positive: true), height: try number(height, positive: true)), context: context)
        }
    }
}

/// PDF-style parenthesized filenames, including escaped parentheses and octal
/// bytes; no evaluation, command interpolation or filesystem interpretation.
private struct SpecialTokens {
    private let chars: [UInt8]
    init(_ string: String) { chars = Array(string.utf8) }
    func all() throws -> [String] {
        var result = [String](), i = 0
        while i < chars.count {
            while i < chars.count && [9,10,13,32].contains(chars[i]) { i += 1 }
            if i == chars.count { break }
            guard result.count < 128 else { throw LaTeXApplePDFError.limit("special tokens") }
            if chars[i] == 40 {
                i += 1; var depth = 1, value = [UInt8]()
                while i < chars.count && depth > 0 {
                    let c = chars[i]; i += 1
                    if c == 92 {
                        guard i < chars.count else { throw LaTeXApplePDFError.invalidDisplayList }
                        let e = chars[i]; i += 1
                        if (48...55).contains(e) {
                            var code = Int(e-48), count = 1
                            while count < 3 && i < chars.count && (48...55).contains(chars[i]) { code=code*8+Int(chars[i]-48); i+=1; count+=1 }
                            value.append(UInt8(code & 255))
                        } else {
                            switch e { case 110: value.append(10); case 114: value.append(13); case 116: value.append(9)
                            case 10: break; case 13: if i < chars.count && chars[i] == 10 { i += 1 }
                            default: value.append(e) }
                        }
                    } else if c == 40 { depth += 1; value.append(c) }
                    else if c == 41 { depth -= 1; if depth > 0 { value.append(c) } }
                    else { value.append(c) }
                }
                guard depth == 0, let token = String(bytes: value, encoding: .utf8), !token.contains("\0") else { throw LaTeXApplePDFError.invalidDisplayList }
                result.append("(" + token + ")")
            } else if chars[i] == 91 || chars[i] == 93 {
                result.append(chars[i] == 91 ? "[" : "]"); i += 1
            } else {
                let start = i
                while i < chars.count && ![9,10,13,32,40,91,93].contains(chars[i]) { i += 1 }
                guard i > start, let token = String(bytes: chars[start..<i], encoding: .utf8) else { throw LaTeXApplePDFError.invalidDisplayList }
                result.append(token)
            }
        }
        return result
    }
}

private final class PDFSink: @unchecked Sendable {
    private var fd: Int32
    private let limit: Int
    private let cancelled: @Sendable () -> Bool
    private var bytes = 0
    private(set) var failure: Error?
    init(fd: Int32, limit: Int, cancelled: @escaping @Sendable () -> Bool) { self.fd=fd; self.limit=limit; self.cancelled=cancelled }
    func put(_ pointer: UnsafeRawPointer, _ count: Int) -> Int {
        if failure != nil { return 0 }
        if cancelled() { failure = CancellationError(); return 0 }
        guard count >= 0, count <= limit-bytes else { failure = LaTeXApplePDFError.limit("PDF bytes"); return 0 }
        var sent = 0
        while sent < count {
            if cancelled() { failure = CancellationError(); break }
            let n = Darwin.write(fd, pointer.advanced(by: sent), count-sent)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { failure = LaTeXApplePDFError.outputFailure; break }
            sent += n
        }
        bytes += sent; return sent
    }
    func close() { if fd >= 0 { _ = Darwin.close(fd); fd = -1 } }
    deinit { close() }
}
