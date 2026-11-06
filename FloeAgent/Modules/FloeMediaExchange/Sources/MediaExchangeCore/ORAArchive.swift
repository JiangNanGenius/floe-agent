// SPDX-License-Identifier: MPL-2.0
//
// OpenRaster 0.0.3 baseline container using the same ZIPFoundation 0.9.20 pin
// as the App. The reader is intentionally strict: unknown elements/attributes,
// nested stacks, masks, text elements, duplicate/unsafe paths and oversized
// entries fail with an explicit error instead of being flattened silently.

import Foundation
import ZIPFoundation

public enum ORAArchive {
    public static let mimetype = Data("image/openraster".utf8)
    public static let stackPath = "stack.xml"
    public static let mergedPath = "mergedimage.png"
    public static let thumbnailPath = "Thumbnails/thumbnail.png"

    public static let allowedCompositeOps: Set<String> = [
        "svg:src-over", "svg:multiply", "svg:screen", "svg:overlay",
        "svg:darken", "svg:lighten", "svg:color-dodge", "svg:color-burn",
        "svg:hard-light", "svg:soft-light", "svg:difference", "svg:color",
        "svg:luminosity", "svg:hue", "svg:saturation", "svg:plus",
        "svg:dst-in", "svg:dst-out", "svg:src-atop", "svg:dst-atop"
    ]

    // MARK: - Write

    public static func write(
        _ document: ORADocument,
        to destination: URL,
        limits: ORALimits = .default,
        overwrite: Bool = false
    ) throws {
        try validateForWrite(document, limits: limits)
        if FileManager.default.fileExists(atPath: destination.path), !overwrite {
            throw ORAError.destinationExists(destination)
        }

        var merged = document.mergedPNG
        if merged == nil {
            let flattened = try ORACompositor.flatten(document, limits: limits)
            merged = try PNGCodec.encode(flattened)
        }
        guard let mergedPNG = merged else {
            throw ORAError.missingEntry(mergedPath)
        }
        try validateMergedPNG(mergedPNG, width: document.width, height: document.height, limits: limits)

        var thumbnail = document.thumbnailPNG
        if thumbnail == nil {
            let mergedImage = try PNGCodec.decode(mergedPNG, maxDimension: limits.maxDimension)
            let scaled = try PNGCodec.scaled(mergedImage, maxDimension: limits.maxThumbnailDimension)
            thumbnail = try PNGCodec.encode(scaled)
        }
        guard let thumbnailPNG = thumbnail else {
            throw ORAError.missingEntry(thumbnailPath)
        }
        try validateThumbnailPNG(thumbnailPNG, limits: limits)

        let xml = try makeStackXML(document)
        let xmlData = Data(xml.utf8)
        guard xmlData.count <= limits.maxStackXMLBytes else {
            throw ORAError.entryTooLarge(path: stackPath, actual: UInt64(xmlData.count), limit: limits.maxStackXMLBytes)
        }

        let total = UInt64(mimetype.count + xmlData.count + mergedPNG.count + thumbnailPNG.count)
            + document.layers.reduce(UInt64(0)) { $0 + UInt64($1.pngData.count) }
        guard total <= UInt64(limits.maxTotalUncompressedBytes) else {
            throw ORAError.totalTooLarge(actual: total, limit: limits.maxTotalUncompressedBytes)
        }

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).ora.partial")
        try? FileManager.default.removeItem(at: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }

        do {
            let archive = try Archive(url: temporary, accessMode: .create)
            try add(archive, path: "mimetype", data: mimetype, compression: .none)
            try add(archive, path: stackPath, data: xmlData, compression: .deflate)
            for (index, layer) in document.layers.enumerated() {
                try add(archive, path: "data/layer\(index).png", data: layer.pngData, compression: .none)
            }
            try add(archive, path: mergedPath, data: mergedPNG, compression: .none)
            try add(archive, path: thumbnailPath, data: thumbnailPNG, compression: .none)
        } catch let error as ORAError {
            throw error
        } catch {
            throw ORAError.writeFailed(String(describing: error))
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                guard overwrite else { throw ORAError.destinationExists(destination) }
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch let error as ORAError {
            throw error
        } catch {
            throw ORAError.writeFailed(String(describing: error))
        }
    }

    // MARK: - Read

    public static func read(from source: URL, limits: ORALimits = .default) throws -> ORADocument {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize <= limits.maxArchiveBytes else {
            throw ORAError.archiveTooLarge(actual: fileSize, limit: limits.maxArchiveBytes)
        }
        let firstEntry = try firstLocalEntryName(source)
        guard firstEntry == "mimetype" else {
            throw ORAError.invalidArchive("mimetype must be the first entry, found \(firstEntry)")
        }

        let archive: Archive
        do {
            archive = try Archive(url: source, accessMode: .read)
        } catch {
            throw ORAError.invalidArchive(String(describing: error))
        }

        var paths = Set<String>()
        var total: UInt64 = 0
        var entries: [String: Entry] = [:]
        var allPaths: [String] = []
        var count = 0
        for entry in archive {
            count += 1
            guard count <= limits.maxEntries else {
                throw ORAError.tooManyEntries(actual: count, limit: limits.maxEntries)
            }
            let path = entry.path
            guard !path.isEmpty else { throw ORAError.unsafePath(path) }
            guard entry.type == .file else {
                throw ORAError.invalidArchive("non-file entry \(path) (\(entry.type))")
            }
            guard paths.insert(path).inserted else {
                throw ORAError.duplicateEntry(path)
            }
            try validatePath(path)
            let (next, overflow) = total.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, next <= UInt64(limits.maxTotalUncompressedBytes) else {
                throw ORAError.totalTooLarge(actual: next, limit: limits.maxTotalUncompressedBytes)
            }
            total = next
            entries[path] = entry
            allPaths.append(path)
        }

        guard let mimeEntry = entries["mimetype"] else {
            throw ORAError.missingEntry("mimetype")
        }
        guard !mimeEntry.isCompressed else {
            throw ORAError.invalidArchive("mimetype entry must be STORED")
        }
        let mime = try extract(archive, entry: mimeEntry, path: "mimetype", maxBytes: 64)
        guard mime == mimetype else {
            throw ORAError.invalidArchive("mimetype content is not image/openraster")
        }
        guard let stackEntry = entries[stackPath] else {
            throw ORAError.missingEntry(stackPath)
        }
        let stackData = try extract(
            archive,
            entry: stackEntry,
            path: stackPath,
            maxBytes: limits.maxStackXMLBytes
        )
        guard let stackString = String(data: stackData, encoding: .utf8) else {
            throw ORAError.invalidXML("stack.xml is not UTF-8")
        }
        if stackString.range(of: "<!DOCTYPE", options: .caseInsensitive) != nil
            || stackString.range(of: "<!ENTITY", options: .caseInsensitive) != nil {
            throw ORAError.invalidXML("DOCTYPE/ENTITY declarations are not accepted")
        }
        let parsed = try parseStackXML(stackString, limits: limits)
        guard !parsed.layerBuilders.isEmpty else {
            throw ORAError.invalidLayerCount(0)
        }
        guard parsed.layerBuilders.count <= limits.maxLayers else {
            throw ORAError.invalidLayerCount(parsed.layerBuilders.count)
        }

        var cache: [String: Data] = [:]
        var layers: [ORALayer] = []
        for builder in parsed.layerBuilders.reversed() {
            guard let entry = entries[builder.src] else {
                throw ORAError.missingEntry(builder.src)
            }
            let pngData: Data
            if let cached = cache[builder.src] {
                pngData = cached
            } else {
                pngData = try extract(
                    archive,
                    entry: entry,
                    path: builder.src,
                    maxBytes: limits.maxLayerBytes
                )
                try validateLayerPNG(pngData, path: builder.src, limits: limits)
                cache[builder.src] = pngData
            }
            layers.append(ORALayer(
                name: builder.name,
                pngData: pngData,
                x: builder.x,
                y: builder.y,
                opacity: builder.opacity,
                visible: builder.visible,
                compositeOp: builder.compositeOp,
                alphaPreserve: builder.alphaPreserve
            ))
        }

        guard let mergedEntry = entries[mergedPath] else {
            throw ORAError.missingEntry(mergedPath)
        }
        let merged = try extract(archive, entry: mergedEntry, path: mergedPath, maxBytes: limits.maxLayerBytes)
        try validateMergedPNG(merged, width: parsed.width, height: parsed.height, limits: limits)
        guard let thumbnailEntry = entries[thumbnailPath] else {
            throw ORAError.missingEntry(thumbnailPath)
        }
        let thumbnail = try extract(
            archive,
            entry: thumbnailEntry,
            path: thumbnailPath,
            maxBytes: limits.maxLayerBytes
        )
        try validateThumbnailPNG(thumbnail, limits: limits)

        let referenced = Set(parsed.layerBuilders.map(\.src))
        let known = referenced.union(["mimetype", stackPath, mergedPath, thumbnailPath])
        let unreferenced = allPaths.filter { !known.contains($0) }
        return ORADocument(
            width: parsed.width,
            height: parsed.height,
            rootName: parsed.rootName,
            xres: parsed.xres,
            yres: parsed.yres,
            layers: layers,
            mergedPNG: merged,
            thumbnailPNG: thumbnail,
            warnings: unreferenced.map { "unreferenced archive entry \($0)" }
        )
    }

    // MARK: - Validation

    public static func validatePath(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 512 else {
            throw ORAError.unsafePath(path)
        }
        guard !path.hasPrefix("/"), !path.hasPrefix("\\"), !path.hasPrefix("~") else {
            throw ORAError.unsafePath(path)
        }
        guard path.range(of: "\\") == nil else {
            throw ORAError.unsafePath(path)
        }
        guard !path.contains(":") else {
            throw ORAError.unsafePath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        for component in components {
            guard !component.isEmpty, component != ".", component != ".." else {
                throw ORAError.unsafePath(path)
            }
            guard component.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw ORAError.unsafePath(path)
            }
        }
    }

    private static func validateForWrite(_ document: ORADocument, limits: ORALimits) throws {
        guard document.width > 0, document.height > 0,
              document.width <= limits.maxDimension, document.height <= limits.maxDimension else {
            throw ORAError.invalidDimensions(width: document.width, height: document.height)
        }
        guard !document.layers.isEmpty, document.layers.count <= limits.maxLayers else {
            throw ORAError.invalidLayerCount(document.layers.count)
        }
        if (document.xres == nil) != (document.yres == nil) {
            throw ORAError.invalidAttribute(element: "image", name: "xres/yres", value: "one of the pair is missing")
        }
        if let xres = document.xres, xres < 1 { throw ORAError.invalidAttribute(element: "image", name: "xres", value: "\(xres)") }
        if let yres = document.yres, yres < 1 { throw ORAError.invalidAttribute(element: "image", name: "yres", value: "\(yres)") }
        for (index, layer) in document.layers.enumerated() {
            guard layer.opacity.isFinite, layer.opacity >= 0, layer.opacity <= 1 else {
                throw ORAError.invalidAttribute(element: "layer", name: "opacity", value: "\(layer.opacity)")
            }
            guard layer.x >= -1_000_000, layer.x <= 1_000_000,
                  layer.y >= -1_000_000, layer.y <= 1_000_000 else {
                throw ORAError.invalidAttribute(element: "layer", name: "x/y", value: "\(layer.x),\(layer.y)")
            }
            guard allowedCompositeOps.contains(layer.compositeOp) else {
                throw ORAError.unsupportedComposite(op: layer.compositeOp)
            }
            try validatePath("data/layer\(index).png")
            let header = try PNGHeader.parse(layer.pngData)
            guard header.bitDepth == 8 else {
                throw ORAError.invalidPNG(path: "data/layer\(index).png", reason: "only 8-bit layer PNGs are supported")
            }
            guard header.width <= limits.maxDimension, header.height <= limits.maxDimension else {
                throw ORAError.invalidPNG(path: "data/layer\(index).png", reason: "dimensions exceed limit")
            }
            guard layer.pngData.count <= limits.maxLayerBytes else {
                throw ORAError.entryTooLarge(
                    path: "data/layer\(index).png",
                    actual: UInt64(layer.pngData.count),
                    limit: limits.maxLayerBytes
                )
            }
        }
    }

    private static func validateLayerPNG(_ data: Data, path: String, limits: ORALimits) throws {
        do {
            let header = try PNGHeader.parse(data)
            guard header.bitDepth == 8 else {
                throw ORAError.invalidPNG(path: path, reason: "only 8-bit layer PNGs are supported")
            }
            guard header.width <= limits.maxDimension, header.height <= limits.maxDimension else {
                throw ORAError.invalidPNG(path: path, reason: "dimensions exceed limit")
            }
        } catch let error as ORAError {
            throw error
        } catch {
            throw ORAError.invalidPNG(path: path, reason: String(describing: error))
        }
    }

    private static func validateMergedPNG(_ data: Data, width: Int, height: Int, limits: ORALimits) throws {
        let header: PNGHeader
        do {
            header = try PNGHeader.parse(data)
        } catch {
            throw ORAError.invalidPNG(path: mergedPath, reason: String(describing: error))
        }
        guard header.width == width, header.height == height else {
            throw ORAError.mergedImageMismatch(expected: "\(width)x\(height)", actual: "\(header.width)x\(header.height)")
        }
        guard header.bitDepth == 8 || header.bitDepth == 16 else {
            throw ORAError.invalidPNG(path: mergedPath, reason: "merged image must be 8 or 16 bits per channel")
        }
        guard header.width <= limits.maxDimension, header.height <= limits.maxDimension else {
            throw ORAError.invalidPNG(path: mergedPath, reason: "dimensions exceed limit")
        }
    }

    private static func validateThumbnailPNG(_ data: Data, limits: ORALimits) throws {
        let header: PNGHeader
        do {
            header = try PNGHeader.parse(data)
        } catch {
            throw ORAError.invalidPNG(path: thumbnailPath, reason: String(describing: error))
        }
        guard header.width <= limits.maxThumbnailDimension, header.height <= limits.maxThumbnailDimension else {
            throw ORAError.thumbnailTooLarge(width: header.width, height: header.height, limit: limits.maxThumbnailDimension)
        }
        guard header.bitDepth == 8 else {
            throw ORAError.invalidPNG(path: thumbnailPath, reason: "thumbnail must be 8 bits per channel")
        }
        guard !header.interlaced else {
            throw ORAError.invalidPNG(path: thumbnailPath, reason: "thumbnail must be non-interlaced")
        }
    }

    // MARK: - ZIP helpers

    private static func add(
        _ archive: Archive,
        path: String,
        data: Data,
        compression: CompressionMethod
    ) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: compression
        ) { position, size in
            let start = Int(position)
            let end = start + size
            guard start >= 0, end >= start, end <= data.count else {
                throw ORAError.writeFailed("provider range for \(path) is out of bounds")
            }
            return data.subdata(in: start..<end)
        }
    }

    private static func extract(
        _ archive: Archive,
        entry: Entry,
        path: String,
        maxBytes: Int
    ) throws -> Data {
        guard entry.uncompressedSize <= UInt64(maxBytes) else {
            throw ORAError.entryTooLarge(path: path, actual: entry.uncompressedSize, limit: maxBytes)
        }
        var data = Data()
        data.reserveCapacity(Int(entry.uncompressedSize))
        do {
            _ = try archive.extract(entry) { chunk in
                guard data.count + chunk.count <= maxBytes else {
                    throw ORAError.entryTooLarge(path: path, actual: UInt64(data.count + chunk.count), limit: maxBytes)
                }
                data.append(chunk)
            }
        } catch let error as ORAError {
            throw error
        } catch {
            throw ORAError.invalidArchive("could not extract \(path): \(error)")
        }
        return data
    }

    /// Reads the first local file header without trusting the central
    /// directory. OpenRaster requires mimetype to be the first ZIP entry.
    private static func firstLocalEntryName(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 30), header.count == 30 else {
            throw ORAError.invalidArchive("file is shorter than a local ZIP header")
        }
        let bytes = [UInt8](header)
        guard bytes[0..<4].elementsEqual([0x50, 0x4B, 0x03, 0x04]) else {
            throw ORAError.invalidArchive("missing local ZIP header signature")
        }
        let nameLength = Int(UInt16(bytes[26]) | UInt16(bytes[27]) << 8)
        let extraLength = Int(UInt16(bytes[28]) | UInt16(bytes[29]) << 8)
        guard nameLength > 0, nameLength <= 512 else {
            throw ORAError.invalidArchive("invalid first entry name length")
        }
        guard let nameData = try handle.read(upToCount: nameLength), nameData.count == nameLength else {
            throw ORAError.invalidArchive("truncated first entry name")
        }
        guard let name = String(data: nameData, encoding: .utf8) else {
            throw ORAError.invalidArchive("first entry name is not UTF-8")
        }
        _ = extraLength
        return name
    }

    // MARK: - stack.xml

    private static func makeStackXML(_ document: ORADocument) throws -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<image version=\"0.0.3\" w=\"\(document.width)\" h=\"\(document.height)\""
        if let xres = document.xres, let yres = document.yres {
            xml += " xres=\"\(xres)\" yres=\"\(yres)\""
        }
        xml += ">\n<stack>\n"
        for (index, layer) in document.layers.enumerated().reversed() {
            xml += "<layer name=\"\(ORAXML.escape(layer.name))\" src=\"data/layer\(index).png\""
            xml += " x=\"\(layer.x)\" y=\"\(layer.y)\""
            xml += " opacity=\"\(ORAXML.number(layer.opacity))\""
            xml += " visibility=\"\(layer.visible ? "visible" : "hidden")\""
            xml += " composite-op=\"\(ORAXML.escape(layer.compositeOp))\""
            if layer.alphaPreserve {
                xml += " alpha-preserve=\"true\""
            }
            xml += "/>\n"
        }
        xml += "</stack>\n</image>\n"
        return xml
    }

    private struct LayerBuilder {
        var name: String
        var src: String
        var x: Int
        var y: Int
        var opacity: Double
        var visible: Bool
        var compositeOp: String
        var alphaPreserve: Bool
    }

    private struct ParsedStack {
        var width: Int
        var height: Int
        var rootName: String?
        var xres: Int?
        var yres: Int?
        var layerBuilders: [LayerBuilder]
    }

    private static func parseStackXML(_ xml: String, limits: ORALimits) throws -> ParsedStack {
        let delegate = StackXMLDelegate(limits: limits)
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            if let failure = delegate.failure { throw failure }
            throw ORAError.invalidXML("XMLParser failed")
        }
        if let failure = delegate.failure { throw failure }
        guard let width = delegate.width, let height = delegate.height else {
            throw ORAError.invalidXML("image width/height is missing")
        }
        try delegate.validateAgainstLimits()
        return ParsedStack(
            width: width,
            height: height,
            rootName: delegate.rootName,
            xres: delegate.xres,
            yres: delegate.yres,
            layerBuilders: delegate.layers
        )
    }

    private final class StackXMLDelegate: NSObject, XMLParserDelegate {
        let limits: ORALimits
        var width: Int?
        var height: Int?
        var version: String?
        var rootName: String?
        var xres: Int?
        var yres: Int?
        var layers: [LayerBuilder] = []
        var failure: ORAError?
        private var stackDepth = 0
        private var sawImage = false
        private var sawRootStack = false
        private var sawRootStackEnd = false

        init(limits: ORALimits) {
            self.limits = limits
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard failure == nil else { return }
            do {
                try handleStart(elementName, attributes: attributeDict)
            } catch let error as ORAError {
                failure = error
                parser.abortParsing()
            } catch {
                failure = .invalidXML(String(describing: error))
                parser.abortParsing()
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard failure == nil else { return }
            if elementName == "stack" {
                stackDepth -= 1
                if stackDepth == 0 {
                    sawRootStackEnd = true
                }
                if stackDepth < 0 {
                    failure = .invalidXML("unbalanced stack element")
                    parser.abortParsing()
                }
            }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            if failure == nil {
                failure = .invalidXML(String(describing: parseError))
            }
        }

        func validateAgainstLimits() throws {
            guard sawImage, sawRootStack, sawRootStackEnd else {
                throw ORAError.invalidXML("image/stack structure is incomplete")
            }
            guard let width, let height, width > 0, height > 0 else {
                throw ORAError.invalidDimensions(width: width ?? 0, height: height ?? 0)
            }
            guard width <= limits.maxDimension, height <= limits.maxDimension else {
                throw ORAError.invalidDimensions(width: width, height: height)
            }
            guard !layers.isEmpty else {
                throw ORAError.invalidLayerCount(0)
            }
            guard layers.count <= limits.maxLayers else {
                throw ORAError.invalidLayerCount(layers.count)
            }
            if (xres == nil) != (yres == nil) {
                throw ORAError.invalidAttribute(element: "image", name: "xres/yres", value: "one of the pair is missing")
            }
        }

        private func handleStart(_ element: String, attributes: [String: String]) throws {
            switch element {
            case "image":
                guard !sawImage else { throw ORAError.invalidXML("duplicate image element") }
                try rejectUnknownAttributes(element, attributes, allowed: ["version", "w", "h", "xres", "yres"])
                sawImage = true
                version = attributes["version"]
                if let version {
                    let parts = version.split(separator: ".")
                    guard parts.count >= 2, parts[0] == "0" else {
                        throw ORAError.invalidXML("unsupported OpenRaster version \(version)")
                    }
                } else {
                    throw ORAError.missingAttribute(element: "image", name: "version")
                }
                width = try requiredPositiveInt(attributes, element: "image", name: "w")
                height = try requiredPositiveInt(attributes, element: "image", name: "h")
                if let value = attributes["xres"] {
                    guard let parsed = Int(value), parsed >= 1 else {
                        throw ORAError.invalidAttribute(element: "image", name: "xres", value: value)
                    }
                    xres = parsed
                }
                if let value = attributes["yres"] {
                    guard let parsed = Int(value), parsed >= 1 else {
                        throw ORAError.invalidAttribute(element: "image", name: "yres", value: value)
                    }
                    yres = parsed
                }
            case "stack":
                guard sawImage else { throw ORAError.invalidXML("stack outside image") }
                if stackDepth == 0 {
                    guard !sawRootStack else { throw ORAError.invalidXML("duplicate root stack") }
                    sawRootStack = true
                    try rejectUnknownAttributes(
                        element,
                        attributes,
                        allowed: ["name", "opacity", "visibility", "composite-op", "isolation"]
                    )
                    rootName = attributes["name"]
                } else {
                    throw ORAError.unsupportedFeature("nested stacks are not supported by the qualification baseline")
                }
                stackDepth += 1
            case "layer":
                guard sawRootStack, stackDepth == 1 else {
                    throw ORAError.invalidXML("layer outside the root stack")
                }
                try rejectUnknownAttributes(
                    element,
                    attributes,
                    allowed: ["name", "src", "x", "y", "opacity", "visibility", "composite-op", "alpha-preserve", "status", "selected"]
                )
                guard let src = attributes["src"] else {
                    throw ORAError.missingAttribute(element: "layer", name: "src")
                }
                try ORAArchive.validatePath(src)
                let x = try optionalInt(attributes, element: "layer", name: "x") ?? 0
                let y = try optionalInt(attributes, element: "layer", name: "y") ?? 0
                guard x >= -1_000_000, x <= 1_000_000, y >= -1_000_000, y <= 1_000_000 else {
                    throw ORAError.invalidAttribute(element: "layer", name: "x/y", value: "\(x),\(y)")
                }
                let opacity: Double
                if let value = attributes["opacity"] {
                    guard let parsed = Double(value), parsed.isFinite, parsed >= 0, parsed <= 1 else {
                        throw ORAError.invalidAttribute(element: "layer", name: "opacity", value: value)
                    }
                    opacity = parsed
                } else {
                    opacity = 1
                }
                let visibility = attributes["visibility"] ?? "visible"
                guard visibility == "visible" || visibility == "hidden" else {
                    throw ORAError.invalidAttribute(element: "layer", name: "visibility", value: visibility)
                }
                let compositeOp = attributes["composite-op"] ?? "svg:src-over"
                guard ORAArchive.allowedCompositeOps.contains(compositeOp) else {
                    throw ORAError.unsupportedComposite(op: compositeOp)
                }
                let alphaPreserve: Bool
                if let value = attributes["alpha-preserve"] {
                    switch value {
                    case "true", "1": alphaPreserve = true
                    case "false", "0": alphaPreserve = false
                    default:
                        throw ORAError.invalidAttribute(element: "layer", name: "alpha-preserve", value: value)
                    }
                } else {
                    alphaPreserve = false
                }
                layers.append(LayerBuilder(
                    name: attributes["name"] ?? "Layer \(layers.count + 1)",
                    src: src,
                    x: x,
                    y: y,
                    opacity: opacity,
                    visible: visibility == "visible",
                    compositeOp: compositeOp,
                    alphaPreserve: alphaPreserve
                ))
            case "text":
                throw ORAError.unsupportedFeature("text elements are not supported by the editable baseline")
            case "mask":
                throw ORAError.unsupportedFeature("layer masks are not part of the OpenRaster baseline used here")
            default:
                throw ORAError.unsupportedFeature("unknown element <\(element)>")
            }
        }

        private func rejectUnknownAttributes(
            _ element: String,
            _ attributes: [String: String],
            allowed: Set<String>
        ) throws {
            for key in attributes.keys {
                if key.hasPrefix("xmlns") || key.hasPrefix("xml:") {
                    continue
                }
                guard allowed.contains(key) else {
                    throw ORAError.unsupportedFeature("unknown attribute \(element).\(key)")
                }
            }
        }

        private func requiredPositiveInt(
            _ attributes: [String: String],
            element: String,
            name: String
        ) throws -> Int {
            guard let value = attributes[name] else {
                throw ORAError.missingAttribute(element: element, name: name)
            }
            guard let parsed = Int(value), parsed > 0 else {
                throw ORAError.invalidAttribute(element: element, name: name, value: value)
            }
            return parsed
        }

        private func optionalInt(
            _ attributes: [String: String],
            element: String,
            name: String
        ) throws -> Int? {
            guard let value = attributes[name] else { return nil }
            guard let parsed = Int(value) else {
                throw ORAError.invalidAttribute(element: element, name: name, value: value)
            }
            return parsed
        }
    }
}
