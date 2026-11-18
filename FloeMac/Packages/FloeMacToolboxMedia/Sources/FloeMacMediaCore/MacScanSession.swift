import Foundation
import Observation
import CoreGraphics
import FloeToolboxCore
import FloeToolboxUtilities

/// Recognition input preparation. This type is deliberately outside the
/// `@MainActor` session so `Task.detached` can prepare the bounded derivative
/// without hopping back to the main actor.
public enum MacScanRecognitionInput {
    /// Longest edge of the derivative handed to the shared image decoder.
    public static let maximumDimension = 2_048

    /// Bounded PNG derivative for Vision. Full-resolution pages are retained
    /// and exported unchanged; only the recognition input is downscaled.
    public static func data(for image: CGImage) throws -> Data {
        let longest = max(image.width, image.height)
        guard longest > maximumDimension else {
            return try OpticsScanExport.png(image)
        }
        let scale = CGFloat(maximumDimension) / CGFloat(longest)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded(.down)))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded(.down)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw MacMediaFailure.engine("recognition-context")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else {
            throw MacMediaFailure.engine("recognition-image")
        }
        return try OpticsScanExport.png(scaled)
    }
}

/// Scan state for one window: live codes, imported/captured pages, on-device
/// recognition and render-ready exports. It deliberately owns no camera and no
/// file access; the Mac camera controller feeds codes, and the AppKit layer
/// turns user panel choices into bytes and destinations.
///
/// All recognition/export work reuses the shared `OpticsRecognition`,
/// `OpticsImageDecoder` and `OpticsScanExport` implementations, including their
/// byte/dimension/page ceilings.
@MainActor
@Observable
public final class MacScanSession {
    public static let maximumResults = OpticsRecognition.maximumResults          // 64
    public static let maximumPages = OpticsScanExport.maximumPages              // 24
    public static let maximumPayloadBytes = OpticsRecognition.maximumPayloadCharacters
    public static let maximumPageTextBytes = 128 * 1_024
    public static let maximumSeenPayloads = 512

    public private(set) var results: [OpticsScanItem] = []
    public private(set) var pages: [MacScanPage] = []
    /// Combined, page-labelled OCR text produced by `recognizeAllPages()`.
    public private(set) var pageText: String?
    public private(set) var notice: MacScanNotice?
    public private(set) var isRecognizing = false
    public private(set) var lastFailure: MacMediaFailure?
    /// One-based page numbers whose most recent recognition failed. Existing
    /// per-page text remains visible, but incomplete documents cannot export.
    public private(set) var failedPageIndices: [Int] = []
    /// True when recognized text cannot fit the explicit UTF-8 byte ceiling.
    public private(set) var textLimitExceeded = false
    /// The shared Vision adapter can swallow errors and truncate observations.
    /// Such text remains visible, but cannot be treated as a complete document.
    public private(set) var ocrCompletenessUnverified = false

    @ObservationIgnored private var seenPayloads = Set<String>()
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var recognitionTask: Task<Void, Never>?
    @ObservationIgnored private var recognizedPageIDs = Set<UUID>()
    @ObservationIgnored private var failedPageIDs = Set<UUID>()
    @ObservationIgnored private var unverifiedPageIDs = Set<UUID>()
    @ObservationIgnored private let textRecognizer: @Sendable (MacScanPage) async throws -> [OpticsScanItem]
    @ObservationIgnored private let testingCompleteTextRecognizer: (@Sendable (MacScanPage) async throws -> [OpticsScanItem])?

    public init() {
        self.testingCompleteTextRecognizer = nil
        self.textRecognizer = { page in
            try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let data = try MacScanRecognitionInput.data(for: page.image)
                try Task.checkCancellation()
                return try OpticsRecognition.recognizeText(imageData: data)
            }.value
        }
    }

    /// Test-only seam. Callers outside this module cannot promote unverified
    /// Vision output into a proven-complete document.
    init(testingCompleteTextRecognizer: @escaping @Sendable (MacScanPage) async throws -> [OpticsScanItem]) {
        self.testingCompleteTextRecognizer = testingCompleteTextRecognizer
        self.textRecognizer = testingCompleteTextRecognizer
    }

    // MARK: - Derived state

    public var hasPages: Bool { !pages.isEmpty }
    public var pageCount: Int { pages.count }
    public var canExportPDF: Bool { !pages.isEmpty }
    public var canExportPNG: Bool { !pages.isEmpty }
    public var canExportTXT: Bool { !(exportableText?.isEmpty ?? true) }
    public var usesText: Bool { results.contains { $0.kind == .text } }

    /// Combined text from a full-document pass, or the per-page text when the
    /// user recognized individual pages instead. Page labels keep the mapping
    /// to the current page order.
    public var exportableText: String? {
        guard !isRecognizing, !pages.isEmpty, failedPageIDs.isEmpty,
              !textLimitExceeded, !ocrCompletenessUnverified,
              pages.allSatisfy({ recognizedPageIDs.contains($0.id) }) else { return nil }
        if let pageText, !pageText.isEmpty { return pageText }
        let sections = pages.enumerated().compactMap { index, page -> String? in
            guard let text = page.text, !text.isEmpty else { return nil }
            return "— \(index + 1) —\n\(text)"
        }
        guard !sections.isEmpty else { return nil }
        let combined = sections.joined(separator: "\n\n")
        guard combined.utf8.count <= Self.maximumPageTextBytes else { return nil }
        return combined
    }

    // MARK: - Live codes

    /// Adds codes delivered by the live camera. Deduplicates against previously
    /// admitted payloads, bounds payload size, and keeps the most recent
    /// `maximumResults` items.
    @discardableResult
    public func acceptLiveCodes(_ codes: [MacCapturedCode]) -> Int {
        var added = 0
        var truncated = false
        for code in codes {
            guard !code.payload.isEmpty,
                  code.payload.utf8.count <= Self.maximumPayloadBytes else { continue }
            guard seenPayloads.count < Self.maximumSeenPayloads else { break }
            let key = "live|\(code.payload)"
            guard !seenPayloads.contains(key) else { continue }
            seenPayloads.insert(key)
            guard results.count < Self.maximumResults else {
                truncated = true
                break
            }
            let label = Self.symbologyLabel(code.symbology)
            let kind: OpticsScanItem.Kind = label.uppercased().contains("QR") ? .qrCode : .barcode
            results.append(OpticsScanItem(kind: kind, payload: code.payload, detail: label))
            added += 1
        }
        if truncated { notice = .resultsTruncated }
        return added
    }

    public static func symbologyLabel(_ rawValue: String) -> String {
        rawValue
            .replacingOccurrences(of: "org.iso.", with: "")
            .replacingOccurrences(of: "org.gs1.", with: "")
            .replacingOccurrences(of: "AVMetadataObjectType", with: "")
    }

    // MARK: - Pages

    /// Adds one decoded page. Pages are capped at `maximumPages`; a later page
    /// is refused with `.pageLimit` rather than silently replacing an earlier
    /// page or pretending the document is complete.
    @discardableResult
    public func addPage(
        _ decoded: OpticsImageDecoder.Decoded,
        source: MacScanPageSource
    ) throws -> MacScanPage {
        guard pages.count < Self.maximumPages else { throw MacMediaFailure.pageLimit }
        let page = MacScanPage(
            image: decoded.image,
            pixelWidth: decoded.pixelWidth,
            pixelHeight: decoded.pixelHeight,
            wasDownsampled: decoded.wasDownsampled,
            source: source
        )
        cancelRecognition()
        pageText = nil
        textLimitExceeded = false
        pages.append(page)
        notice = .pageAdded(pages.count)
        return page
    }

    /// Imports encoded image bytes through the shared bounded decoder
    /// (20 MiB / 8192 px / 32 MP ceilings) and appends one page.
    @discardableResult
    public func addImportedImage(data: Data) throws -> MacScanPage {
        let decoded: OpticsImageDecoder.Decoded
        do {
            decoded = try OpticsImageDecoder.decode(data)
        } catch {
            throw Self.map(error, fallback: .unreadable)
        }
        return try addPage(decoded, source: .imported)
    }

    /// Appends a page captured by the Mac camera. The camera returns encoded
    /// still bytes, decoded here through the shared bounded decoder.
    @discardableResult
    public func addCapturedPage(data: Data) throws -> MacScanPage {
        let decoded: OpticsImageDecoder.Decoded
        do {
            decoded = try OpticsImageDecoder.decode(data)
        } catch {
            throw Self.map(error, fallback: .captureFailed("decode"))
        }
        return try addPage(decoded, source: .camera)
    }

    public func removePage(id: UUID) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        // A page set change invalidates any in-flight text pass.
        cancelRecognition()
        pages.remove(at: index)
        recognizedPageIDs.remove(id)
        failedPageIDs.remove(id)
        unverifiedPageIDs.remove(id)
        ocrCompletenessUnverified = !unverifiedPageIDs.isEmpty
        refreshFailedPageIndices()
        textLimitExceeded = false
        // The combined text described the previous page set; drop it rather
        // than exporting a document that no longer matches the pages.
        pageText = nil
        updateCombinedTextLimit()
        if failedPageIDs.isEmpty && !textLimitExceeded { lastFailure = nil }
        notice = .pageRemoved
    }

    public func clear() {
        cancelRecognition()
        results = []
        pages = []
        pageText = nil
        seenPayloads = []
        recognizedPageIDs = []
        failedPageIDs = []
        unverifiedPageIDs = []
        failedPageIndices = []
        textLimitExceeded = false
        ocrCompletenessUnverified = false
        notice = .cleared
        lastFailure = nil
    }

    // MARK: - Recognition

    /// Runs barcode + text recognition for one retained page and merges the
    /// results. Uses the shared decoder/recognizer path; a cancelled or stale
    /// run leaves existing results untouched.
    @discardableResult
    public func recognizePage(id: UUID) async -> Int {
        guard !isRecognizing,
              let index = pages.firstIndex(where: { $0.id == id }) else { return 0 }
        generation &+= 1
        let token = generation
        isRecognizing = true
        lastFailure = nil
        pageText = nil
        recognizedPageIDs.remove(id)
        failedPageIDs.remove(id)
        unverifiedPageIDs.remove(id)
        ocrCompletenessUnverified = !unverifiedPageIDs.isEmpty
        refreshFailedPageIndices()
        textLimitExceeded = false
        let page = pages[index]
        do {
            let items: [OpticsScanItem]
            if let testingCompleteTextRecognizer {
                items = try await testingCompleteTextRecognizer(page)
            } else {
                items = try await Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let data = try MacScanRecognitionInput.data(for: page.image)
                    try Task.checkCancellation()
                    return try OpticsRecognition.recognizeAll(imageData: data)
                }.value
            }
            guard token == generation, !Task.isCancelled else { return 0 }
            isRecognizing = false
            guard let current = pages.firstIndex(where: { $0.id == id }) else { return 0 }
            pages[current].text = try Self.joinedText(items)
            recognizedPageIDs.insert(id)
            if testingCompleteTextRecognizer == nil { unverifiedPageIDs.insert(id) }
            ocrCompletenessUnverified = !unverifiedPageIDs.isEmpty
            updateCombinedTextLimit()
            let (added, truncated) = merge(items)
            if !textLimitExceeded && !(ocrCompletenessUnverified && added == 0) {
                notice = truncated ? .resultsTruncated : (added > 0 ? .recognized(added) : .noResults)
            } else if ocrCompletenessUnverified && added == 0 {
                notice = nil
            }
            return added
        } catch is CancellationError {
            if token == generation { isRecognizing = false }
            return 0
        } catch {
            guard token == generation else { return 0 }
            isRecognizing = false
            failedPageIDs.insert(id)
            refreshFailedPageIndices()
            textLimitExceeded = (error as? MacMediaFailure) == .exportTooLarge
            lastFailure = Self.map(error, fallback: .captureFailed("recognition"))
            notice = nil
            return 0
        }
    }

    /// Sequentially OCRs every retained page, cancelling between pages. Produces
    /// the labelled text used by TXT export; text stays bounded at
    /// `maximumPageTextBytes`. Recognition uses `MacScanRecognitionInput` so the
    /// Vision work never runs on the main actor.
    public func recognizeAllPages() async {
        guard !pages.isEmpty, !isRecognizing else { return }
        generation &+= 1
        let token = generation
        isRecognizing = true
        lastFailure = nil
        pageText = nil
        recognizedPageIDs = []
        failedPageIDs = []
        unverifiedPageIDs = []
        failedPageIndices = []
        textLimitExceeded = false
        ocrCompletenessUnverified = false
        let snapshot = pages
        let recognizer = textRecognizer
        let completenessVerified = testingCompleteTextRecognizer != nil
        let task = Task { @MainActor [weak self] in
            var sections: [String] = []
            for (index, page) in snapshot.enumerated() {
                if Task.isCancelled { break }
                do {
                    let items = try await recognizer(page)
                    if Task.isCancelled { break }
                    let text = try Self.joinedText(items)
                    self?.store(text: text, pageID: page.id, token: token, completenessVerified: completenessVerified)
                    if let text, !text.isEmpty { sections.append("— \(index + 1) —\n\(text)") }
                } catch is CancellationError {
                    if Task.isCancelled { break }
                    self?.recordRecognitionFailure(CancellationError(), pageID: page.id, token: token)
                    continue
                } catch {
                    self?.recordRecognitionFailure(error, pageID: page.id, token: token)
                    continue
                }
            }
            self?.finishPagesText(sections: sections, token: token, pageCount: snapshot.count)
        }
        recognitionTask = task
        await task.value
    }

    public func cancelRecognition() {
        generation &+= 1
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecognizing = false
    }

    private func store(text: String?, pageID: UUID, token: UInt64, completenessVerified: Bool) {
        guard token == generation else { return }
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        pages[index].text = text
        recognizedPageIDs.insert(pageID)
        failedPageIDs.remove(pageID)
        if completenessVerified { unverifiedPageIDs.remove(pageID) }
        else { unverifiedPageIDs.insert(pageID) }
        ocrCompletenessUnverified = !unverifiedPageIDs.isEmpty
        refreshFailedPageIndices()
    }

    private func finishPagesText(sections: [String], token: UInt64, pageCount: Int) {
        guard token == generation else { return }
        isRecognizing = false
        recognitionTask = nil
        let combined = sections.joined(separator: "\n\n")
        if combined.utf8.count > Self.maximumPageTextBytes {
            textLimitExceeded = true
            lastFailure = .exportTooLarge
            pageText = nil
            notice = nil
            return
        }
        guard failedPageIDs.isEmpty, recognizedPageIDs.count == pageCount else {
            pageText = nil
            notice = nil
            if lastFailure == nil { lastFailure = .captureFailed("ocr-incomplete") }
            return
        }
        pageText = combined.isEmpty ? nil : combined
        if ocrCompletenessUnverified {
            notice = nil
            return
        }
        notice = .pagesComplete(pageCount)
    }

    private func recordRecognitionFailure(_ error: Error, pageID: UUID, token: UInt64) {
        guard token == generation else { return }
        recognizedPageIDs.remove(pageID)
        failedPageIDs.insert(pageID)
        refreshFailedPageIndices()
        if (error as? MacMediaFailure) == .exportTooLarge {
            textLimitExceeded = true
            lastFailure = .exportTooLarge
        } else if lastFailure == nil {
            lastFailure = .captureFailed("ocr-incomplete")
        }
    }

    private func refreshFailedPageIndices() {
        failedPageIndices = pages.enumerated().compactMap { index, page in
            failedPageIDs.contains(page.id) ? index + 1 : nil
        }
    }

    private func updateCombinedTextLimit() {
        let total = pages.enumerated().compactMap { index, page -> String? in
            guard let text = page.text, !text.isEmpty else { return nil }
            return "— \(index + 1) —\n\(text)"
        }.joined(separator: "\n\n")
        textLimitExceeded = total.utf8.count > Self.maximumPageTextBytes
        if textLimitExceeded { lastFailure = .exportTooLarge; notice = nil }
    }

    // MARK: - Exports

    /// Exports one page as PNG. Defaults to the most recently added page.
    public func makePNG(pageID: UUID? = nil) throws -> MacExportArtifact {
        let page: MacScanPage?
        if let pageID {
            page = pages.first { $0.id == pageID }
        } else {
            page = pages.last
        }
        guard let page else { throw MacMediaFailure.emptyExport }
        do {
            let data = try OpticsScanExport.png(page.image)
            return MacExportArtifact(format: .png, data: data,
                                     suggestedFilename: MacExportNaming.suggestedName(format: .png))
        } catch {
            throw Self.map(error, fallback: .engine("png-export"))
        }
    }

    /// Exports every retained page as a multi-page PDF in page order.
    public func makePDF() throws -> MacExportArtifact {
        guard !pages.isEmpty else { throw MacMediaFailure.emptyExport }
        do {
            let data = try OpticsScanExport.pdf(pages: pages.map(\.image))
            return MacExportArtifact(format: .pdf, data: data,
                                     suggestedFilename: MacExportNaming.suggestedName(format: .pdf))
        } catch {
            throw Self.map(error, fallback: .engine("pdf-export"))
        }
    }

    /// Exports recognized page text. Requires `recognizeAllPages()` output;
    /// partial or empty results are not presented as a complete document.
    public func makeTXT() throws -> MacExportArtifact {
        guard !textLimitExceeded else { throw MacMediaFailure.exportTooLarge }
        guard !ocrCompletenessUnverified else {
            throw MacMediaFailure.captureFailed("ocr-completeness-unverified")
        }
        guard !isRecognizing, failedPageIDs.isEmpty,
              pages.allSatisfy({ recognizedPageIDs.contains($0.id) }) else {
            throw MacMediaFailure.captureFailed("ocr-incomplete")
        }
        guard let text = exportableText, !text.isEmpty else { throw MacMediaFailure.emptyExport }
        do {
            let data = try OpticsScanExport.text(text)
            return MacExportArtifact(format: .txt, data: data,
                                     suggestedFilename: MacExportNaming.suggestedName(format: .txt))
        } catch {
            throw Self.map(error, fallback: .engine("text-export"))
        }
    }

    // MARK: - Helpers

    private func merge(_ items: [OpticsScanItem]) -> (added: Int, truncated: Bool) {
        var added = 0
        var truncated = false
        for item in items {
            guard item.payload.utf8.count <= Self.maximumPayloadBytes else { continue }
            guard seenPayloads.count < Self.maximumSeenPayloads else { break }
            let key = "\(item.kind.rawValue)|\(item.payload)"
            guard !seenPayloads.contains(key) else { continue }
            seenPayloads.insert(key)
            guard results.count < Self.maximumResults else {
                truncated = true
                break
            }
            results.append(item)
            added += 1
        }
        return (added, truncated)
    }

    private static func joinedText(_ items: [OpticsScanItem]) throws -> String? {
        let lines = items.filter { $0.kind == .text }.map(\.payload)
        guard !lines.isEmpty else { return nil }
        let text = lines.joined(separator: "\n")
        guard text.utf8.count <= maximumPageTextBytes else { throw MacMediaFailure.exportTooLarge }
        return text
    }

    private static func map(_ error: Error, fallback: MacMediaFailure) -> MacMediaFailure {
        if let failure = error as? MacMediaFailure { return failure }
        if let toolbox = error as? ToolboxError {
            switch toolbox {
            case .limit: return .fileTooLarge
            case .invalid, .unsupported: return fallback
            case .truncated: return .unreadable
            default: return fallback
            }
        }
        if error is CancellationError { return fallback }
        return fallback
    }
}
