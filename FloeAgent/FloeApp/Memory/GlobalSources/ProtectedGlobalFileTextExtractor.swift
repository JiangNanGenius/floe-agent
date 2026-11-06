// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(PDFKit)
import Foundation
import UIKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import Darwin
import FloeCore
import FloeDocuments

/// Only accepts URLs supplied by an existing native read lease. This service
/// never obtains a bookmark, imports a document, runs a tool, or opens a model.
/// One actor serializes native parsing; no detached worker outlives its call.
actor ProtectedGlobalFileTextExtractor {
    nonisolated static let revision = "native-file-text-1"
    private let limits: GlobalFileTextLimits

    init(limits: GlobalFileTextLimits = .init()) { self.limits = limits }

    func text(from url: URL) async throws -> String? {
        let budget = GlobalFileTextBudget(seconds: limits.maximumSeconds)
        do {
            try budget.check()
            let ext = url.pathExtension.lowercased()
            guard ext == "pdf" || OfficeDocumentKind(url: url) != nil || Self.imageExtensions.contains(ext)
                || UTType(filenameExtension: ext)?.conforms(to: .image) == true else { return nil }
            let input = try GlobalExtractionFile.read(url, maximumBytes: limits.maximumFileBytes, budget: budget)
            let result: String?
            if ext == "pdf" {
                guard input.data.starts(with: Data("%PDF-".utf8)) else { return nil }
                result = try Self.pdf(input.data, limits: limits, budget: budget)
            } else if OfficeDocumentKind(url: url) != nil {
                guard input.data.starts(with: [0x50, 0x4B]) else { return nil }
                // Use the actual OOXML inspector, including its ZIP entry,
                // expanded-size, XML entity, field and revision checks.
                try input.checkCurrent()
                let document = try Self.office(input, budget: budget)
                try budget.check()
                try input.checkCurrent()
                guard document.fields.count < 20_000 else { return nil }
                result = try Self.join(document.fields.map(\.text), limit: limits.maximumCharacters, budget: budget)
            } else if Self.imageExtensions.contains(ext) || UTType(filenameExtension: ext)?.conforms(to: .image) == true {
                result = try Self.image(input.data, limits: limits, budget: budget)
            } else {
                // Legacy Office, locked documents, raw audio/video without an
                // owner-bound saved transcript and unsupported types stay pending.
                result = nil
            }
            try budget.check()
            try input.checkCurrent()
            let text = result?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // No title, error message or guessed transcript is returned as body.
            // The provider preserves needsTextExtraction and can retry later.
            return nil
        }
    }

    private nonisolated static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]

    private nonisolated static func office(_ input: GlobalExtractionFile, budget: GlobalFileTextBudget) throws -> OfficeDocumentSnapshot {
        var coordinationError: NSError?
        var result: Result<OfficeDocumentSnapshot, Error>?
        NSFileCoordinator().coordinate(readingItemAt: input.url, options: [.withoutChanges], error: &coordinationError) { readable in
            result = Result {
                try budget.check()
                guard try GlobalExtractionFile.checkedURL(readable) == input.url else { throw GlobalExtractionUnavailable.changed }
                try input.checkCurrent()
                let value = try OfficeDocumentService.inspect(url: readable)
                try budget.check()
                try input.checkCurrent()
                return value
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw GlobalExtractionUnavailable.unsupported }
        return try result.get()
    }

    private nonisolated static func pdf(_ data: Data, limits: GlobalFileTextLimits, budget: GlobalFileTextBudget) throws -> String? {
        // Every PDFKit object stays inside the existing serialized gate and
        // ObjC exception boundary. Only value text/image bytes leave it.
        let pages: [GlobalPDFTextPage]? = try PDFKitGate.run {
            try withPDFExceptionGuard {
                try budget.check()
                guard let document = PDFDocument(data: data), !document.isLocked,
                      document.pageCount > 0, document.pageCount <= limits.maximumPDFPages else { return nil }
                var pages: [GlobalPDFTextPage] = [], characters = 0, rasterPages = 0
                for index in 0..<document.pageCount {
                    try budget.check()
                    guard let page = document.page(at: index) else { return nil }
                    let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    characters += text.count
                    guard characters <= limits.maximumCharacters else { return nil }
                    if !text.isEmpty { pages.append(.text(text)); continue }
                    rasterPages += 1
                    guard rasterPages <= limits.maximumPDFOCRPages else { return nil }
                    let bounds = page.bounds(for: .cropBox)
                    guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return nil }
                    let scale = min(1, CGFloat(limits.maximumImageEdge) / max(bounds.width, bounds.height))
                    let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
                    let image = page.thumbnail(of: size, for: .cropBox)
                    guard let bytes = image.pngData(), bytes.count <= limits.maximumRasterBytes else { return nil }
                    pages.append(.raster(bytes, max(1, Int(image.size.width * image.scale)), max(1, Int(image.size.height * image.scale))))
                }
                try budget.check()
                return pages
            }
        }
        guard let pages else { return nil }
        var text: [String] = []
        for page in pages {
            try budget.check()
            switch page {
            case .text(let value): text.append(value)
            case .raster(let bytes, let width, let height):
                guard let value = try ocr(bytes, width: width, height: height, limits: limits, budget: budget) else { return nil }
                text.append(value)
            }
        }
        return try join(text, limit: limits.maximumCharacters, budget: budget)
    }

    private nonisolated static func image(_ data: Data, limits: GlobalFileTextLimits, budget: GlobalFileTextBudget) throws -> String? {
        try budget.check()
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue.isFinite, height.doubleValue.isFinite,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= Double(limits.maximumSourcePixels),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: limits.maximumImageEdge
              ] as CFDictionary) else { return nil }
        try budget.check()
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= limits.maximumRasterBytes else { return nil }
        return try ocr(output as Data, width: image.width, height: image.height, limits: limits, budget: budget)
    }

    private nonisolated static func ocr(_ data: Data, width: Int, height: Int, limits: GlobalFileTextLimits, budget: GlobalFileTextBudget) throws -> String? {
        try budget.check()
        let regions = try VisualTextRecognizer.recognize(imageData: data, pixelWidth: width, pixelHeight: height,
            referencePrefix: "source", limit: limits.maximumOCRLines + 1)
        try budget.check()
        guard regions.count <= limits.maximumOCRLines else { return nil }
        return try join(regions.map(\.text), limit: limits.maximumCharacters, budget: budget)
    }

    private nonisolated static func join(_ strings: [String], limit: Int, budget: GlobalFileTextBudget) throws -> String? {
        var text = ""
        for value in strings {
            try budget.check()
            guard value.count <= limit - text.count - (text.isEmpty ? 0 : 1) else { return nil }
            if !text.isEmpty { text += "\n" }
            text += value
        }
        return text
    }
}

nonisolated struct GlobalFileTextLimits: Sendable {
    var maximumFileBytes = 16 * 1_024 * 1_024
    var maximumCharacters = 200_000
    var maximumPDFPages = 64
    var maximumPDFOCRPages = 3
    var maximumImageEdge = 1_600
    var maximumSourcePixels = 48_000_000
    var maximumRasterBytes = 12 * 1_024 * 1_024
    var maximumOCRLines = 512
    var maximumSeconds = 12.0
}

private nonisolated enum GlobalPDFTextPage { case text(String); case raster(Data, Int, Int) }
nonisolated enum GlobalExtractionUnavailable: Error { case unsupported, changed, timeBudget }

/// The current native APIs are synchronous. This bounds admission and each
/// page/field/line boundary; a PDFKit/Office/Vision call already in progress
/// cannot be forcibly killed. No timed-out result can be committed as text.
nonisolated struct GlobalFileTextBudget: Sendable {
    let deadline: ContinuousClock.Instant
    init(seconds: Double) { deadline = .now.advanced(by: .milliseconds(Int64(max(1, min(30, seconds)) * 1_000))) }
    func check() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw GlobalExtractionUnavailable.timeBudget }
    }
}

nonisolated struct GlobalExtractionFingerprint: Equatable, Sendable {
    let device: UInt64, inode: UInt64, bytes: Int64, seconds: Int64, nanoseconds: Int64
    init(_ value: stat) {
        device = UInt64(UInt32(bitPattern: value.st_dev)); inode = UInt64(value.st_ino); bytes = value.st_size
        seconds = Int64(value.st_mtimespec.tv_sec); nanoseconds = Int64(value.st_mtimespec.tv_nsec)
    }
}

nonisolated struct GlobalExtractionFile: Sendable {
    let url: URL
    let data: Data
    let fingerprint: GlobalExtractionFingerprint

    static func revision(_ url: URL, maximumBytes: Int = 16 * 1_024 * 1_024) throws -> String {
        let file = try checkedURL(url)
        var current = stat()
        guard lstat(file.path, &current) == 0, (current.st_mode & S_IFMT) == S_IFREG,
              current.st_size >= 0, current.st_size <= Int64(maximumBytes) else { throw GlobalExtractionUnavailable.unsupported }
        let value = GlobalExtractionFingerprint(current)
        return [ProtectedGlobalFileTextExtractor.revision, String(value.device), String(value.inode), String(value.bytes),
            String(value.seconds), String(value.nanoseconds)].joined(separator: ":")
    }

    static func checkedURL(_ url: URL) throws -> URL {
        guard url.isFileURL, !url.path.contains("\0") else { throw GlobalExtractionUnavailable.unsupported }
        let path = url.standardizedFileURL
        guard GlobalSourceTextPolicy.permittedName(path.path) else { throw GlobalExtractionUnavailable.unsupported }
        // Permit only Darwin's fixed /var -> /private/var alias, used by native
        // container URLs. A linked file/other linked ancestor fails even inside
        // a granted root; a resolved target cannot mint source authorization.
        let canonical = path.resolvingSymlinksInPath()
        let expected = path.path.hasPrefix("/var/") ? "/private" + path.path : path.path
        guard canonical.path == expected else { throw GlobalExtractionUnavailable.unsupported }
        let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw GlobalExtractionUnavailable.unsupported }
        return canonical
    }
    static func read(_ url: URL, maximumBytes: Int, budget: GlobalFileTextBudget) throws -> Self {
        let url = try checkedURL(url)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw GlobalExtractionUnavailable.unsupported }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= Int64(maximumBytes) else { throw GlobalExtractionUnavailable.unsupported }
        let fingerprint = GlobalExtractionFingerprint(info)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try budget.check()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0, count <= maximumBytes - data.count else { throw GlobalExtractionUnavailable.changed }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, GlobalExtractionFingerprint(after) == fingerprint,
              Int64(data.count) == fingerprint.bytes else { throw GlobalExtractionUnavailable.changed }
        let result = Self(url: url, data: data, fingerprint: fingerprint)
        try result.checkCurrent()
        return result
    }
    func checkCurrent() throws {
        _ = try Self.checkedURL(url)
        var current = stat()
        guard lstat(url.path, &current) == 0, (current.st_mode & S_IFMT) == S_IFREG,
              GlobalExtractionFingerprint(current) == fingerprint else { throw GlobalExtractionUnavailable.changed }
    }
}
#endif
