import Foundation
import Observation
import FloeToolboxUtilities

public enum MacScannerDraftError: Error, Equatable { case unavailable, tooManyPixels, tooManyBytes, invalidDestination }
public enum MacScannerExportOutcome: Equatable, Sendable { case committed, failed, uncertain }
public struct MacScannerExportReceipt: Equatable, Sendable {
    public let id: UUID
    public let revision: UInt64
    public let destination: URL
    public let outcome: MacScannerExportOutcome
}

/// In-memory, application-owned scan draft. It does not claim persistence
/// across process termination. The real host has not yet adopted this type.
@MainActor @Observable
public final class MacScannerDraftOwner {
    public struct ExportRequest {
        fileprivate let id: UUID
        fileprivate let revision: UInt64
        fileprivate let surface: UUID
        fileprivate let artifact: MacExportArtifact
        public var format: MacScanExportFormat { artifact.format }
        public var suggestedFilename: String { artifact.suggestedFilename }
    }
    public typealias Writer = @Sendable (MacExportArtifact, URL) async -> MacScannerExportOutcome
    public static let maximumDraftPixels = 32_000_000
    public static let maximumDraftImageBytes = 128 * 1_024 * 1_024
    public static let maximumDraftInputBytes = 64 * 1_024 * 1_024
    private enum State { case active, preparing, terminal }
    private let session: MacScanSession
    private let pixelLimit: Int
    private let imageByteLimit: Int
    private let inputByteLimit: Int
    private var inputBytesByPage: [UUID: Int] = [:]
    private let writer: Writer
    private var state: State = .active
    private var terminationEpoch = UUID()
    private var visible = false
    private var surface = UUID()
    private var revision: UInt64 = 0
    private var discardApproved = false
    private var outstandingExportID: UUID?
    private var exportTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var recognitionTicket = UUID()
    public private(set) var lastReceipt: MacScannerExportReceipt?

    public init() {
        self.session = MacScanSession()
        self.pixelLimit = Self.maximumDraftPixels
        self.imageByteLimit = Self.maximumDraftImageBytes
        self.inputByteLimit = Self.maximumDraftInputBytes
        self.writer = { artifact, destination in
            do {
                // The live writer has no post-commit path-identity receipt.
                // Until the reviewed writer lands, never claim confirmation.
                try MacSafeFileWriter.write(artifact.data, to: destination)
                return .uncertain
            }
            catch { return .uncertain }
        }
    }

    init(session: MacScanSession, pixelLimit: Int = maximumDraftPixels,
         imageByteLimit: Int = maximumDraftImageBytes, inputByteLimit: Int = maximumDraftInputBytes,
         writer: @escaping Writer) {
        precondition(session.pages.isEmpty && session.results.isEmpty)
        self.session = session; self.pixelLimit = max(1, min(pixelLimit, Self.maximumDraftPixels))
        self.imageByteLimit = max(1, min(imageByteLimit, Self.maximumDraftImageBytes))
        self.inputByteLimit = max(1, min(inputByteLimit, Self.maximumDraftInputBytes))
        self.writer = writer
    }

    public var pages: [MacScanPage] { session.pages }
    public var results: [OpticsScanItem] { session.results }
    public var pageCount: Int { session.pageCount }
    public var isRecognizing: Bool { session.isRecognizing || recognitionTask != nil }
    public var failedPageIndices: [Int] { session.failedPageIndices }
    public var textLimitExceeded: Bool { session.textLimitExceeded }
    public var ocrCompletenessUnverified: Bool { session.ocrCompletenessUnverified }
    public var notice: MacScanNotice? { session.notice }
    public var lastFailure: MacMediaFailure? { session.lastFailure }
    public var canExportPNG: Bool { session.canExportPNG }
    public var canExportPDF: Bool { session.canExportPDF }
    public var canExportTXT: Bool { session.canExportTXT }
    public var hasDraft: Bool { !session.pages.isEmpty || !session.results.isEmpty }
    public var hasPendingWork: Bool { exportTask != nil || recognitionTask != nil }
    public var currentRevision: UInt64 { revision }
    public var draftPixels: Int { session.pages.reduce(0) { $0 + $1.pixelWidth * $1.pixelHeight } }
    public var draftImageBytes: Int { session.pages.reduce(0) { $0 + $1.image.bytesPerRow * $1.pixelHeight } }
    public var draftInputBytes: Int { inputBytesByPage.values.reduce(0, +) }

    @discardableResult
    public func appear() -> UUID { visible = true; surface = UUID(); return surface }
    public func disappear() { visible = false; surface = UUID(); outstandingExportID = nil }
    public func isCurrentSurface(_ ticket: UUID) -> Bool { state == .active && visible && surface == ticket }

    public func acceptLiveCodes(_ codes: [MacCapturedCode], ticket: UUID) throws {
        try requireSurface(ticket)
        if session.acceptLiveCodes(codes) > 0 { changed() }
    }

    public func addImage(_ data: Data, source: MacScanPageSource, ticket: UUID) throws {
        try requireSurface(ticket)
        guard data.count <= inputByteLimit, draftInputBytes <= inputByteLimit - data.count else {
            throw MacScannerDraftError.tooManyBytes
        }
        let decoded = try OpticsImageDecoder.decode(data)
        let (pixels, overflow) = decoded.pixelWidth.multipliedReportingOverflow(by: decoded.pixelHeight)
        guard !overflow, pixels <= pixelLimit, draftPixels <= pixelLimit - pixels else {
            throw MacScannerDraftError.tooManyPixels
        }
        let (imageBytes, imageOverflow) = decoded.image.bytesPerRow.multipliedReportingOverflow(by: decoded.pixelHeight)
        guard !imageOverflow, imageBytes > 0, imageBytes <= imageByteLimit,
              draftImageBytes <= imageByteLimit - imageBytes else { throw MacScannerDraftError.tooManyBytes }
        let page = try session.addPage(decoded, source: source)
        inputBytesByPage[page.id] = data.count
        recognitionTicket = UUID()
        changed()
    }

    public func removePage(_ id: UUID, ticket: UUID) throws {
        try requireSurface(ticket)
        guard session.pages.contains(where: { $0.id == id }) else { return }
        session.removePage(id: id)
        inputBytesByPage.removeValue(forKey: id)
        recognitionTicket = UUID()
        changed()
    }

    public func clear(ticket: UUID, expectedRevision: UInt64? = nil) throws {
        try requireSurface(ticket)
        if let expectedRevision, expectedRevision != revision { throw MacScannerDraftError.unavailable }
        guard hasDraft else { return }
        session.clear()
        inputBytesByPage.removeAll()
        recognitionTicket = UUID()
        changed()
    }

    public func recognizeAll(ticket: UUID) throws {
        try startRecognition(pageID: nil, ticket: ticket)
    }

    public func recognizePage(_ pageID: UUID, ticket: UUID) throws {
        try startRecognition(pageID: pageID, ticket: ticket)
    }

    private func startRecognition(pageID: UUID?, ticket: UUID) throws {
        try requireSurface(ticket)
        guard recognitionTask == nil, !session.pages.isEmpty else { throw MacScannerDraftError.unavailable }
        if let pageID, !session.pages.contains(where: { $0.id == pageID }) { throw MacScannerDraftError.unavailable }
        changed()
        let run = UUID()
        recognitionTicket = run
        recognitionTask = Task { @MainActor [self] in
            guard state == .active, recognitionTicket == run else {
                recognitionTask = nil
                return
            }
            if let pageID { _ = await session.recognizePage(id: pageID) }
            else { await session.recognizeAllPages() }
            // Results can arrive after an export captured the earlier page
            // snapshot. Mark completion so that receipt is not mislabeled as
            // a later revision, even when recognition was cancelled.
            changed()
            recognitionTask = nil
        }
    }

    public func prepareExport(_ format: MacScanExportFormat, pageID: UUID? = nil, ticket: UUID) throws -> ExportRequest {
        try requireSurface(ticket)
        guard exportTask == nil else { throw MacScannerDraftError.unavailable }
        let artifact: MacExportArtifact
        switch format {
        case .png: artifact = try session.makePNG(pageID: pageID)
        case .pdf: artifact = try session.makePDF()
        case .txt: artifact = try session.makeTXT()
        case .csv: throw MacScannerDraftError.unavailable
        }
        let id = UUID()
        outstandingExportID = id
        return ExportRequest(id: id, revision: revision, surface: ticket, artifact: artifact)
    }

    /// The destination must come from the user's explicit save selection.
    /// A draft mutation or surface close while the panel is open invalidates
    /// the pending request, before any writer is invoked.
    public func commitExport(_ request: ExportRequest, to destination: URL) throws {
        try requireSurface(request.surface)
        guard destination.isFileURL else { throw MacScannerDraftError.invalidDestination }
        guard exportTask == nil, request.revision == revision, outstandingExportID == request.id else {
            throw MacScannerDraftError.unavailable
        }
        outstandingExportID = nil
        let writer = self.writer
        exportTask = Task { @MainActor [self] in
            let outcome = await writer(request.artifact, destination)
            lastReceipt = MacScannerExportReceipt(id: request.id, revision: request.revision,
                                                   destination: destination, outcome: outcome)
            exportTask = nil
        }
    }

    public func beginTermination() {
        guard state == .active else { return }
        state = .preparing; surface = UUID(); discardApproved = false; outstandingExportID = nil
        terminationEpoch = UUID()
        recognitionTicket = UUID()
        session.cancelRecognition()
    }
    public func cancelTermination() {
        guard state == .preparing else { return }
        state = .active; surface = UUID(); discardApproved = false; terminationEpoch = UUID()
    }
    /// Explicit confirmation only; a successful image export is not a saved
    /// scanner workspace and must not imply that all draft data is preserved.
    public func allowExitDiscardingDraft() -> Bool {
        guard state == .preparing, !hasPendingWork else { return false }
        discardApproved = true
        return true
    }
    public func drain(timeout: TimeInterval = 5) async -> Bool {
        guard state == .preparing else { return false }
        let expected = terminationEpoch
        let deadline = ContinuousClock.now + .seconds(max(0, timeout))
        while hasPendingWork {
            guard state == .preparing, terminationEpoch == expected, ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        return state == .preparing && terminationEpoch == expected && (!hasDraft || discardApproved)
    }
    public func shutdown() {
        state = .terminal; surface = UUID(); recognitionTicket = UUID(); terminationEpoch = UUID(); session.cancelRecognition()
    }

    private func requireSurface(_ ticket: UUID) throws {
        guard state == .active, visible, surface == ticket else { throw MacScannerDraftError.unavailable }
    }
    private func changed() { revision &+= 1; discardApproved = false; outstandingExportID = nil }
}
