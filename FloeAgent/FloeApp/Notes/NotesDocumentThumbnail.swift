// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit
import Foundation
import QuickLookThumbnailing
import FloeNotes
import FloeDocuments
import PencilKit
import os

/// Where a Notes library cover actually came from. A cover is only ever
/// published together with this source, so a placeholder or a generic system
/// icon can never be presented, cached or asserted as document content.
enum NotesDocumentCoverSource: String, Sendable, CaseIterable {
    /// A real system Quick Look thumbnail of the document's own bytes. The
    /// generator is rejected when it only offers `QLThumbnailRepresentation
    /// .RepresentationType.icon`, which is a file-type glyph, not content.
    case quickLookThumbnail = "quickLook"
    /// A bounded, native OOXML content summary rendered from the document's
    /// own text/cells. This is explicitly not the original Office layout.
    case officeContentSummary = "officeContentSummary"
    /// A real render of the document's first note page (handwriting, images,
    /// PDF background, text elements) in stable page coordinates.
    case notePage = "notePage"
    /// A real, bounded overview render of the mind map node tree.
    case mindMap = "mindMap"
    /// A real render of an engineering drawing through the bundled viewer
    /// (single bounded offscreen WebKit host), never a generic icon.
    case engineeringPreview = "engineeringPreview"
    /// No content cover is available for this document. The card shows the
    /// explicit unsupported placeholder; nothing is faked.
    case unsupported = "unsupported"
    /// Not rendered yet.
    case none = "none"

    var hasContent: Bool {
        switch self {
        case .quickLookThumbnail, .officeContentSummary, .notePage, .mindMap, .engineeringPreview: true
        case .unsupported, .none: false
        }
    }
}

/// The settled result of one cover render.
struct NotesDocumentCoverOutcome {
    var image: UIImage?
    var source: NotesDocumentCoverSource
    var diagnosis: String
}

/// Bounded in-memory cache for Notes grid thumbnails.
///
/// The key always contains the document id plus the immutable resource id and
/// revision, so a thumbnail can never be shown for a different revision or a
/// different document. Only real generated covers are cached, together with
/// their `NotesDocumentCoverSource`; a placeholder/icon is never stored.
@MainActor
private final class NotesDocumentThumbnailCache {
    static let shared = NotesDocumentThumbnailCache()

    final class Entry {
        let image: UIImage
        let source: NotesDocumentCoverSource
        init(image: UIImage, source: NotesDocumentCoverSource) {
            self.image = image
            self.source = source
        }
    }

    private let cache = NSCache<NSString, Entry>()

    private init() {
        cache.countLimit = 80
        cache.totalCostLimit = 48 * 1024 * 1024
    }
    func entry(for key: String) -> Entry? { cache.object(forKey: key as NSString) }
    func store(_ entry: Entry, for key: String) {
        let cost = Int(entry.image.size.width * entry.image.size.height * entry.image.scale * entry.image.scale * 4)
        cache.setObject(entry, forKey: key as NSString, cost: max(cost, 1))
    }
}

/// One grid/list preview.
///
/// A single `NotesDocumentCoverService` decides the real source for every
/// supported `NoteDocument` kind. Office covers use a system Quick Look
/// thumbnail when it is real content, fall back to a bounded native OOXML
/// content summary when the system cannot render the format offline, and show
/// an explicit unsupported state otherwise. Notebooks render their first page,
/// mind maps render their node tree, and engineering drawings render through
/// the one shared bundled viewer before Quick Look is considered. No heavy
/// Office engine is started for a card, and a generic file icon is never
/// treated as a cover.
@MainActor
struct NotesDocumentThumbnail: View {
    let document: NoteDocument
    let store: NotesStore?
    /// Reports the settled cover source and the document revision it belongs to,
    /// so the owning card can expose both to accessibility and UI acceptance
    /// tests. Never reports `.none`.
    var onSource: ((NotesDocumentCoverSource, Int) -> Void)?
    @State private var image: UIImage?
    @State private var source: NotesDocumentCoverSource = .none
    @State private var unsupportedDetail: String?
    /// The key of the newest load. A cancelled predecessor compares against this
    /// before touching `image`, so it can never clear or overwrite a newer card.
    @State private var currentKey: String?

    private static let thumbnailSize = CGSize(width: 320, height: 420)
    /// A card must not ask Quick Look to decode an arbitrarily large file.
    private static let maximumThumbnailSourceBytes = 128 * 1024 * 1024

    init(document: NoteDocument, store: NotesStore?,
         onSource: ((NotesDocumentCoverSource, Int) -> Void)? = nil) {
        self.document = document
        self.store = store
        self.onSource = onSource
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(uiColor: .secondarySystemBackground)
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                placeholder
            }
            if source == .officeContentSummary {
                Text(String(localized: "notes.cover.badge.summary", defaultValue: "Summary"))
                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.thinMaterial, in: Capsule())
                    .padding(6)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("notes.thumbnail.\(document.kind.rawValue).\(document.title)")
        .accessibilityLabel(placeholderTitle)
        .accessibilityValue(source.rawValue)
        .task(id: thumbnailKey) { await load() }
    }

    /// Document identity + immutable resource + revision; never reuse a stale key.
    private var thumbnailKey: String {
        switch document.kind {
        case .office:
            "\(document.id.uuidString):office:\(document.officeResourceID?.uuidString ?? "none"):\(document.revision)"
        case .engineering:
            "\(document.id.uuidString):engineering:\(document.engineeringResourceID?.uuidString ?? "none"):\(document.revision)"
        default:
            "\(document.id.uuidString):note:\(document.revision)"
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: symbolName).font(.largeTitle).foregroundStyle(.tint)
            Text(placeholderTitle).font(.caption).lineLimit(3).multilineTextAlignment(.center)
            if let unsupportedDetail {
                Text(unsupportedDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
            }
        }.padding()
    }

    private var symbolName: String {
        switch document.kind {
        case .mindMap: "point.3.connected.trianglepath.dotted"
        case .office: "doc.richtext"
        case .engineering: "doc.viewfinder"
        case .notebook: "book.closed"
        }
    }

    private var placeholderTitle: String {
        switch document.kind {
        case .mindMap: document.nodes.first?.title ?? document.title
        case .office: document.officeFileName ?? document.title
        case .engineering: document.engineeringFileName ?? document.title
        case .notebook: document.title
        }
    }

    /// Adopt the key of the newest task and drop the previous card's pixels
    /// before any suspension, so a changed revision never shows the old image.
    private func load() async {
        let key = thumbnailKey
        currentKey = key
        if let cached = NotesDocumentThumbnailCache.shared.entry(for: key) {
            image = cached.image
            source = cached.source
            unsupportedDetail = nil
            onSource?(cached.source, document.revision)
            return
        }
        image = nil
        source = .none
        unsupportedDetail = nil
        guard !Task.isCancelled else { return }
        let outcome = await NotesDocumentCoverService.render(document: document, store: store,
                                                             size: Self.thumbnailSize,
                                                             maximumSourceBytes: Self.maximumThumbnailSourceBytes)
        guard !Task.isCancelled else { return }
        if let value = outcome.image {
            NotesDocumentThumbnailCache.shared.store(.init(image: value, source: outcome.source), for: key)
        }
        apply(outcome, key: key)
    }

    /// Publish the settled cover only when this task still owns the card. A
    /// cancelled predecessor that resumes late can populate the cache yet can
    /// never clear or replace the newer card's state.
    private func apply(_ outcome: NotesDocumentCoverOutcome, key: String) {
        guard key == currentKey else { return }
        image = outcome.image
        source = outcome.source
        unsupportedDetail = outcome.source == .unsupported ? outcome.diagnosis : nil
        onSource?(outcome.source, document.revision)
    }
}

/// Bounded retry policy for one Quick Look cover request. Every value is finite:
/// a card can never poll Quick Look forever, and cancellation always wins.
struct NotesOfficeThumbnailPolicy: Sendable {
    /// Hard cap on a single generator request.
    var perAttemptTimeout: Duration = .seconds(15)
    /// Total attempts including the first; attempts two and three may recover
    /// a transient first-attempt failure (e.g. a cold-start generator launch
    /// race).
    var maxAttempts: Int = 3
    /// Absolute wall-clock budget for the whole card request.
    var totalDeadline: Duration = .seconds(45)
    var initialBackoff: Duration = .milliseconds(500)
    var maximumBackoff: Duration = .seconds(2)
}

/// The single Quick Look request path shared by the product grid and the
/// NativeNotes qualification tests. One bounded request at a time, explicit
/// generator cancellation on timeout/cancel, and structured diagnostics for
/// every failure. A `.icon` representation is never accepted as content: it is
/// a file-type glyph, not a document preview. Product logs never carry document
/// file names, staged paths or raw error text.
@MainActor
enum NotesOfficeThumbnailGenerator {
    private static let logger = Logger(subsystem: "ai.floe.notes", category: "office-thumbnail")

    /// The settled result of one bounded request attempt.
    struct AttemptOutcome: Sendable {
        var image: UIImage?
        /// Full diagnosis for local test triage; never written to os.Logger.
        var diagnosis: String
        var timedOut: Bool
        var elapsed: Duration
        /// Numeric generator error identity (domain + code); the only error
        /// detail product logs may carry.
        var errorDomain: String? = nil
        var errorCode: Int? = nil
        /// True when Quick Look only offered its generic file-type icon. That
        /// is not content and is retried no further.
        var isIconFallback: Bool = false
    }

    /// The settled result of a whole bounded card request.
    struct CardOutcome: Sendable {
        var image: UIImage?
        var attempts: Int
        var diagnosis: String
        var elapsed: Duration
        var timedOut: Bool = false
        var errorDomain: String? = nil
        var errorCode: Int? = nil
        var wasIconFallback: Bool = false
    }

    static let cardPolicy = NotesOfficeThumbnailPolicy()

    /// A representation is only usable as content when Quick Look did not fall
    /// back to the generic file-type icon.
    nonisolated static func isContentRepresentation(_ type: QLThumbnailRepresentation.RepresentationType) -> Bool {
        type != .icon
    }

    /// Bounded retry over `request`: at most `policy.maxAttempts` tries, an
    /// absolute `policy.totalDeadline`, cancellable backoff between attempts,
    /// and no attempt ever started after cancellation. A generic `.icon`
    /// representation is terminal: there is no point retrying an unsupported
    /// generator, and it must never be returned as a cover.
    static func thumbnail(url: URL, size: CGSize, fileExtension: String = "",
                          policy: NotesOfficeThumbnailPolicy = NotesOfficeThumbnailGenerator.cardPolicy,
                          request: @escaping (URL, CGSize, Duration) async -> AttemptOutcome = requestThumbnail) async -> CardOutcome {
        let start = ContinuousClock.now
        func elapsed() -> Duration { start.duration(to: ContinuousClock.now) }
        var attempt = 0
        var backoff = policy.initialBackoff
        var last = AttemptOutcome(image: nil, diagnosis: "no attempt ran", timedOut: false, elapsed: .zero)
        while attempt < policy.maxAttempts,
              !Task.isCancelled,
              elapsed() < policy.totalDeadline {
            attempt += 1
            let remaining = policy.totalDeadline - elapsed()
            let outcome = await request(url, size, min(policy.perAttemptTimeout, remaining))
            if outcome.isIconFallback {
                return CardOutcome(image: nil, attempts: attempt,
                                   diagnosis: outcome.diagnosis, elapsed: elapsed(),
                                   wasIconFallback: true)
            }
            if let image = outcome.image {
                return CardOutcome(image: image, attempts: attempt,
                                   diagnosis: outcome.diagnosis, elapsed: elapsed())
            }
            last = outcome
            logRetry(fileExtension: fileExtension, attempt: attempt, maxAttempts: policy.maxAttempts,
                     elapsed: elapsed(), outcome: outcome)
            guard attempt < policy.maxAttempts, elapsed() < policy.totalDeadline else { break }
            let remainingAfterAttempt = policy.totalDeadline - elapsed()
            try? await Task.sleep(for: min(backoff, remainingAfterAttempt))
            backoff = min(backoff * 2, policy.maximumBackoff)
        }
        return CardOutcome(image: nil, attempts: attempt, diagnosis: last.diagnosis,
                           elapsed: elapsed(), timedOut: last.timedOut,
                           errorDomain: last.errorDomain, errorCode: last.errorCode)
    }

    /// Bounded and cancellable Quick Look request: one hard timeout, no polling,
    /// explicit cancellation of the generator request, and a guarded single
    /// resume shared by the generator callback, the timeout and cancellation.
    static func requestThumbnail(url: URL, size: CGSize, timeout: Duration) async -> AttemptOutcome {
        let start = ContinuousClock.now
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 1, representationTypes: .thumbnail)
        let state = NotesThumbnailRequestState(request: request)
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            state.cancel(reason: "per-attempt timeout")
        }
        defer { timeoutTask.cancel() }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AttemptOutcome, Never>) in
                guard state.attach(continuation) else { return }
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
                    let nsError = error.map { $0 as NSError }
                    // A generic file-type icon is not document content. Reject
                    // it explicitly so it can never be cached or shown as a
                    // thumbnail, and so the bounded loop does not waste retries.
                    let isIcon = representation.map { !isContentRepresentation($0.type) } ?? false
                    let image = isIcon ? nil : representation?.uiImage
                    let diagnosis: String?
                    if let error { diagnosis = String(describing: error) }
                    else if isIcon { diagnosis = "generic icon representation" }
                    else if image == nil { diagnosis = "empty representation" }
                    else { diagnosis = nil }
                    Task { @MainActor in
                        state.finish(image: image, diagnosis: diagnosis, timedOut: false,
                                     errorDomain: nsError?.domain, errorCode: nsError?.code,
                                     isIconFallback: isIcon)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in state.cancel(reason: "task cancelled") }
        }
        return AttemptOutcome(image: result.image, diagnosis: result.diagnosis, timedOut: result.timedOut,
                              elapsed: start.duration(to: ContinuousClock.now),
                              errorDomain: result.errorDomain, errorCode: result.errorCode,
                              isIconFallback: result.isIconFallback)
    }

    /// Logs carry only the validated extension, attempt, elapsed time and a
    /// non-sensitive failure category — never a document file name, staged
    /// path or raw error description.
    private static func category(of outcome: AttemptOutcome) -> String {
        if outcome.diagnosis == "task cancelled" { return "cancelled" }
        if outcome.isIconFallback { return "icon only" }
        if outcome.timedOut { return "timed out" }
        if let domain = outcome.errorDomain, let code = outcome.errorCode { return "\(domain) \(code)" }
        return "empty representation"
    }

    static func logSuccess(fileExtension: String, attempt: Int, elapsed: Duration) {
        logger.info("[thumbnail] .\(fileExtension, privacy: .public) rendered on attempt \(attempt, privacy: .public) in \(elapsed, privacy: .public)s")
    }

    static func logRetry(fileExtension: String, attempt: Int, maxAttempts: Int, elapsed: Duration, outcome: AttemptOutcome) {
        logger.error("[thumbnail] .\(fileExtension, privacy: .public) attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public) failed after \(elapsed, privacy: .public)s: \(category(of: outcome), privacy: .public)")
    }

    static func logUnavailable(fileExtension: String, outcome: CardOutcome) {
        logger.error("[thumbnail] .\(fileExtension, privacy: .public) no content cover after \(outcome.attempts, privacy: .public) attempt(s), \(outcome.elapsed, privacy: .public)s; last: \(outcome.wasIconFallback ? "icon only" : "unavailable", privacy: .public)")
    }
}

/// Quick Look keys off the file extension, while a Notes resource is stored at
/// an extensionless SHA-256 CAS path. Stage a uniquely scoped copy whose name
/// carries the validated extension; callers remove the whole directory once the
/// request settles or is cancelled.
enum NotesOfficeThumbnailStaging {
    static let supportedExtensions: Set<String> = [
        "docx", "doc", "odt", "rtf", "xlsx", "xls", "ods", "pptx", "ppt", "odp"
    ]

    /// The same basename/extension rule the document model enforces, repeated so
    /// a thumbnail request never stages an unexpected or traversing name.
    static func validatedExtension(of fileName: String, allowing allowed: Set<String> = supportedExtensions) -> String? {
        guard !fileName.isEmpty, fileName == (fileName as NSString).lastPathComponent else { return nil }
        let ext = (fileName as NSString).pathExtension.lowercased()
        return allowed.contains(ext) ? ext : nil
    }

    static func stage(source: URL, fileExtension: String) async throws -> URL {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try copy(source: source, fileExtension: fileExtension)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    private static func copy(source: URL, fileExtension: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-notes-thumb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("preview.\(fileExtension)")
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return destination
    }

    static func remove(_ stagedFile: URL) {
        try? FileManager.default.removeItem(at: stagedFile.deletingLastPathComponent())
    }
}

/// Process-wide bound on concurrent Quick Look generation. A scrolling grid can
/// spawn many cards at once; at most two previews decode a source file at a
/// time and the rest wait for a slot. Cancelling a queued card resumes it at
/// once without ever handing it a slot.
@MainActor
final class NotesOfficeThumbnailGate {
    static let shared = NotesOfficeThumbnailGate()
    private let limit: Int
    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []

    init(limit: Int = 2) { self.limit = max(1, limit) }

    func acquire(id: UUID) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                if active < limit {
                    active += 1
                    continuation.resume(returning: true)
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(returning: false)
    }

    func release() {
        if waiters.isEmpty { active = max(0, active - 1) }
        else { waiters.removeFirst().1.resume(returning: true) }
    }
}

/// Main-actor serialization makes registration + generator start atomic with
/// respect to cancellation. A cancelled request can never start afterwards.
@MainActor
private final class NotesThumbnailRequestState {
    private let request: QLThumbnailGenerator.Request
    private var continuation: CheckedContinuation<NotesOfficeThumbnailGenerator.AttemptOutcome, Never>?
    private var finished = false

    init(request: QLThumbnailGenerator.Request) { self.request = request }

    func attach(_ continuation: CheckedContinuation<NotesOfficeThumbnailGenerator.AttemptOutcome, Never>) -> Bool {
        guard !finished else {
            continuation.resume(returning: NotesOfficeThumbnailGenerator.AttemptOutcome(image: nil,
                                                          diagnosis: "request settled before attach",
                                                          timedOut: false, elapsed: .zero))
            return false
        }
        self.continuation = continuation
        return true
    }

    func finish(image: UIImage?, diagnosis: String?, timedOut: Bool,
                errorDomain: String? = nil, errorCode: Int? = nil, isIconFallback: Bool = false) {
        guard !finished else { return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: NotesOfficeThumbnailGenerator.AttemptOutcome(image: image,
                                                       diagnosis: diagnosis ?? "request settled without a result",
                                                       timedOut: timedOut, elapsed: .zero,
                                                       errorDomain: errorDomain, errorCode: errorCode,
                                                       isIconFallback: isIconFallback))
    }

    func cancel(reason: String) {
        guard !finished else { return }
        QLThumbnailGenerator.shared.cancel(request)
        finish(image: nil, diagnosis: reason, timedOut: reason == "per-attempt timeout")
    }
}

/// One bounded, cancellable cover render for any supported `NoteDocument`.
/// Every kind has a real source: Office uses a system content thumbnail or a
/// bounded native OOXML summary; notebooks render their first page; mind maps
/// render their node tree; engineering drawings render through the bundled
/// viewer and only fall back to Quick Look if the bundled viewer cannot paint
/// its own geometry. When no real source exists the outcome is explicitly
/// `.unsupported` with a diagnosis — never an icon pretending to be content.
@MainActor
enum NotesDocumentCoverService {
    private nonisolated static let maximumSummaryFields = 240
    /// The native OOXML summary is a fallback; parsing a huge package in the UI
    /// process is never worth it, so it is capped well below the Quick Look
    /// bound and always runs off the main actor.
    static let maximumSummarySourceBytes = 48 * 1024 * 1024

    static func render(document: NoteDocument, store: NotesStore?, size: CGSize,
                       maximumSourceBytes: Int) async -> NotesDocumentCoverOutcome {
        guard let store else {
            return .init(image: nil, source: .unsupported,
                         diagnosis: String(localized: "notes.cover.error.storeUnavailable", defaultValue: "Notes storage is not ready"))
        }
        switch document.kind {
        case .office:
            return await officeCover(document: document, store: store, size: size, maximumSourceBytes: maximumSourceBytes)
        case .notebook:
            return await notePageCover(document: document, store: store)
        case .mindMap:
            return mindMapCover(document: document, size: size)
        case .engineering:
            return await engineeringCover(document: document, store: store, size: size, maximumSourceBytes: maximumSourceBytes)
        }
    }

    // MARK: - Office

    private static func officeCover(document: NoteDocument, store: NotesStore, size: CGSize,
                                    maximumSourceBytes: Int) async -> NotesDocumentCoverOutcome {
        guard let resourceID = document.officeResourceID, let fileName = document.officeFileName,
              let fileExtension = NotesOfficeThumbnailStaging.validatedExtension(of: fileName) else {
            return .init(image: nil, source: .unsupported,
                         diagnosis: String(localized: "notes.cover.office.invalidResource", defaultValue: "The Office file reference is invalid"))
        }
        let source: URL
        do { source = try await store.resourceURL(resourceID) } catch {
            return .init(image: nil, source: .unsupported,
                         diagnosis: String(localized: "notes.cover.error.resourceUnavailable", defaultValue: "The file is unavailable"))
        }
        var sourceBytes = 0
        do {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let byteCount = values.fileSize,
                  byteCount <= maximumSourceBytes else {
                return .init(image: nil, source: .unsupported,
                             diagnosis: String(localized: "notes.cover.office.unreadableOrTooLarge", defaultValue: "The Office file is too large or unreadable"))
            }
            sourceBytes = byteCount
        } catch {
            return .init(image: nil, source: .unsupported,
                         diagnosis: String(localized: "notes.cover.error.unreadable", defaultValue: "The file is unreadable"))
        }
        if Task.isCancelled {
            return .init(image: nil, source: .none, diagnosis: "cancelled")
        }

        // The shared slot is acquired BEFORE staging: a staged copy can be up
        // to 128 MiB, so copying must be bounded by the same gate as
        // generation. It also bounds the native OOXML summary digest below.
        let slotID = UUID()
        guard await NotesOfficeThumbnailGate.shared.acquire(id: slotID) else {
            return .init(image: nil, source: .none, diagnosis: "cancelled")
        }
        defer { NotesOfficeThumbnailGate.shared.release() }
        if Task.isCancelled { return .init(image: nil, source: .none, diagnosis: "cancelled") }

        var quickLookDiagnosis = "not attempted"
        do {
            let staged = try await NotesOfficeThumbnailStaging.stage(source: source, fileExtension: fileExtension)
            defer { NotesOfficeThumbnailStaging.remove(staged) }
            let outcome = await NotesOfficeThumbnailGenerator.thumbnail(url: staged, size: size,
                                                                        fileExtension: fileExtension)
            if Task.isCancelled { return .init(image: nil, source: .none, diagnosis: "cancelled") }
            if let image = outcome.image {
                NotesOfficeThumbnailGenerator.logSuccess(fileExtension: fileExtension, attempt: outcome.attempts,
                                                         elapsed: outcome.elapsed)
                return .init(image: image, source: .quickLookThumbnail, diagnosis: "quick look")
            }
            NotesOfficeThumbnailGenerator.logUnavailable(fileExtension: fileExtension, outcome: outcome)
            quickLookDiagnosis = outcome.wasIconFallback
                ? String(localized: "notes.cover.office.iconOnly", defaultValue: "Quick Look returned only a generic icon")
                : String(localized: "notes.cover.office.noQuickLook", defaultValue: "Quick Look did not produce a content thumbnail")
        } catch is CancellationError {
            return .init(image: nil, source: .none, diagnosis: "cancelled")
        } catch {
            quickLookDiagnosis = String(localized: "notes.cover.office.quickLookUnavailable", defaultValue: "Quick Look is unavailable")
        }

        // The native OOXML inspector understands modern docx/xlsx/pptx only;
        // legacy/binary and OpenDocument formats stay explicitly unsupported.
        guard let kind = OfficeDocumentKind(rawValue: fileExtension) else {
            return .init(image: nil, source: .unsupported, diagnosis: quickLookDiagnosis)
        }
        // The summary fallback parses the package off the main actor. It is
        // capped below the Quick Look bound so a card can never inflate a large
        // ZIP in the UI process.
        guard sourceBytes <= maximumSummarySourceBytes else {
            return .init(image: nil, source: .unsupported, diagnosis: quickLookDiagnosis)
        }
        let snapshot: OfficeDocumentSnapshot? = await Task.detached(priority: .utility) {
            try? OfficeDocumentService.inspect(url: source)
        }.value
        if Task.isCancelled { return .init(image: nil, source: .none, diagnosis: "cancelled") }
        guard let snapshot, !snapshot.fields.isEmpty else {
            return .init(image: nil, source: .unsupported, diagnosis: quickLookDiagnosis)
        }
        // Drawing is a pure, bounded render (<= 240 fields); keep it off the
        // main actor as well so a card never blocks scrolling.
        let summary: UIImage? = await Task.detached(priority: .utility) {
            contentSummary(snapshot: snapshot, kind: kind, size: size)
        }.value
        if Task.isCancelled { return .init(image: nil, source: .none, diagnosis: "cancelled") }
        guard let summary else {
            return .init(image: nil, source: .unsupported, diagnosis: quickLookDiagnosis)
        }
        return .init(image: summary, source: .officeContentSummary, diagnosis: "native content summary")
    }

    // MARK: - Notebook page

    private static func notePageCover(document: NoteDocument, store: NotesStore) async -> NotesDocumentCoverOutcome {
        guard let page = document.pages.first else {
            return .init(image: nil, source: .unsupported,
                         diagnosis: String(localized: "notes.cover.notebook.noPage", defaultValue: "There is no page to render"))
        }
        do {
            let background = (try await NoteFileImporter.background(page: page, store: store)).flatMap { UIImage(data: $0) }
            let images = try await NoteFileImporter.elementImages(page: page, store: store)
            let ink: PKDrawing?
            if let id = page.drawingResourceID { ink = try PKDrawing(data: Data(contentsOf: await store.resourceURL(id))) }
            else { ink = nil }
            try Task.checkCancellation()
            let scale = min(240 / page.width, 320 / page.height)
            let size = CGSize(width: page.width * scale, height: page.height * scale)
            let rendered = UIGraphicsImageRenderer(size: size).image { context in
                context.cgContext.scaleBy(x: scale, y: scale)
                NotePageRenderer.draw(page, background: background, images: images.compactMapValues { UIImage(data: $0) })
                ink?.image(from: CGRect(x: 0, y: 0, width: page.width, height: page.height), scale: 240 / page.width)
                    .draw(in: CGRect(x: 0, y: 0, width: page.width, height: page.height))
            }
            return .init(image: rendered, source: .notePage, diagnosis: "first page")
        } catch {
            return .init(image: nil, source: .unsupported,
                         diagnosis: String(localized: "notes.cover.notebook.readFailed", defaultValue: "The page could not be read"))
        }
    }

    // MARK: - Mind map

    private static func mindMapCover(document: NoteDocument, size: CGSize) -> NotesDocumentCoverOutcome {
        guard !document.nodes.isEmpty else {
            return .init(image: nil, source: .unsupported,
                         diagnosis: String(localized: "notes.cover.mindmap.empty", defaultValue: "The mind map has no topics"))
        }
        let layout = mindMapLayout(nodes: document.nodes, connections: document.connections, maximumRows: 40)
        guard !layout.rows.isEmpty else {
            return .init(image: nil, source: .unsupported,
                         diagnosis: String(localized: "notes.cover.mindmap.unrenderable", defaultValue: "The mind map has no renderable topics"))
        }
        let rendered = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.saveGState()
            context.cgContext.clip(to: CGRect(origin: .zero, size: size))
            defer { context.cgContext.restoreGState() }

            let rowHeight: CGFloat = 24
            let top: CGFloat = 12
            let rowRects: [CGRect] = layout.rows.enumerated().map { index, row in
                let inset = min(CGFloat(row.depth), 6) * 18
                return CGRect(x: 12 + inset, y: top + CGFloat(index) * rowHeight,
                              width: size.width - 24 - inset, height: rowHeight - 5)
            }
            let connector = UIColor(white: 0.45, alpha: 0.55)
            for (index, row) in layout.rows.enumerated() {
                guard let parent = row.parentIndex, let parentRect = rowRects.indices.contains(parent) ? rowRects[parent] : nil else { continue }
                let childRect = rowRects[index]
                let elbowX = childRect.minX - 7
                let path = UIBezierPath()
                path.move(to: CGPoint(x: parentRect.minX + 8, y: parentRect.midY))
                path.addLine(to: CGPoint(x: elbowX, y: parentRect.midY))
                path.addLine(to: CGPoint(x: elbowX, y: childRect.midY))
                path.addLine(to: CGPoint(x: childRect.minX, y: childRect.midY))
                connector.setStroke()
                path.lineWidth = 1.2
                path.stroke()
            }
            // Explicit cross-links (MindMapConnection) are a real part of the
            // map structure, so they are drawn too, not just the parent tree.
            let link = UIColor.systemGray2
            link.setStroke()
            for edge in layout.edges {
                guard rowRects.indices.contains(edge.from), rowRects.indices.contains(edge.to) else { continue }
                let path = UIBezierPath()
                path.move(to: CGPoint(x: rowRects[edge.from].midX, y: rowRects[edge.from].midY))
                path.addLine(to: CGPoint(x: rowRects[edge.to].midX, y: rowRects[edge.to].midY))
                path.lineWidth = 1
                path.setLineDash([3, 3], count: 2, phase: 0)
                path.stroke()
            }
            for (index, row) in layout.rows.enumerated() {
                let rect = rowRects[index]
                let isRoot = row.depth == 0
                if isRoot {
                    UIColor(red: 0.145, green: 0.388, blue: 0.922, alpha: 1).setFill()
                } else {
                    UIColor.secondarySystemFill.setFill()
                }
                UIBezierPath(roundedRect: rect, cornerRadius: 7).fill()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: isRoot ? UIFont.boldSystemFont(ofSize: 11) : UIFont.systemFont(ofSize: 10),
                    .foregroundColor: isRoot ? UIColor.white : UIColor.label
                ]
                (row.title as NSString).draw(in: rect.insetBy(dx: 6, dy: 3.5), withAttributes: attributes)
            }
        }
        return .init(image: rendered, source: .mindMap, diagnosis: "node tree")
    }

    struct MindMapRow { let title: String; let depth: Int; let parentIndex: Int? }
    struct MindMapEdge { let from: Int; let to: Int; let title: String }
    struct MindMapLayout { let rows: [MindMapRow]; let edges: [MindMapEdge] }

    /// A bounded depth-first tree of the node structure, stable by `order` and
    /// parent id, plus the explicit cross-links. Titles and edges make the cover
    /// a real structural render rather than a file name.
    static func mindMapLayout(nodes: [MindMapNode], connections: [MindMapConnection],
                              maximumRows: Int) -> MindMapLayout {
        var children: [UUID: [MindMapNode]] = [:]
        let known = Set(nodes.map(\.id))
        for node in nodes {
            guard let parent = node.parentID, known.contains(parent) else { continue }
            children[parent, default: []].append(node)
        }
        for key in children.keys {
            children[key]?.sort { ($0.order, $0.title) < ($1.order, $1.title) }
        }
        let roots = nodes.filter { node in
            guard let parent = node.parentID else { return true }
            return !known.contains(parent)
        }.sorted { ($0.order, $0.title) < ($1.order, $1.title) }

        var rows: [MindMapRow] = []
        var indexByID: [UUID: Int] = [:]
        var visited = Set<UUID>()
        func visit(_ node: MindMapNode, depth: Int, parentIndex: Int?) {
            guard rows.count < maximumRows, !visited.contains(node.id) else { return }
            visited.insert(node.id)
            let rowIndex = rows.count
            indexByID[node.id] = rowIndex
            rows.append(MindMapRow(title: node.title.isEmpty
                                   ? String(localized: "notes.cover.mindmap.untitled", defaultValue: "Untitled topic")
                                   : node.title,
                                   depth: depth, parentIndex: parentIndex))
            for child in children[node.id] ?? [] { visit(child, depth: depth + 1, parentIndex: rowIndex) }
        }
        for root in roots { visit(root, depth: 0, parentIndex: nil) }
        // Any node left out by a cycle is still shown as a root row.
        for node in nodes where !visited.contains(node.id) { visit(node, depth: 0, parentIndex: nil) }

        var edges: [MindMapEdge] = []
        for connection in connections {
            guard let from = indexByID[connection.from], let to = indexByID[connection.to],
                  from != to else { continue }
            let isTreeEdge = rows[to].parentIndex == from || rows[from].parentIndex == to
            if !isTreeEdge {
                edges.append(MindMapEdge(from: from, to: to, title: connection.title))
            }
        }
        return MindMapLayout(rows: rows, edges: edges)
    }

    // MARK: - Engineering / CAD

    private static func engineeringCover(document: NoteDocument, store: NotesStore, size: CGSize,
                                         maximumSourceBytes: Int) async -> NotesDocumentCoverOutcome {
        guard let resourceID = document.engineeringResourceID, let fileName = document.engineeringFileName,
              let fileExtension = NotesOfficeThumbnailStaging.validatedExtension(
                of: fileName, allowing: NoteDocument.supportedEngineeringFileExtensions) else {
            return .init(image: nil, source: .unsupported,
                         diagnosis: String(localized: "notes.cover.engineering.invalidResource", defaultValue: "The drawing reference is invalid"))
        }
        let source: URL
        do { source = try await store.resourceURL(resourceID) } catch {
            return .init(image: nil, source: .unsupported,
                         diagnosis: String(localized: "notes.cover.error.resourceUnavailable", defaultValue: "The file is unavailable"))
        }
        do {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let byteCount = values.fileSize,
                  byteCount <= maximumSourceBytes else {
                return .init(image: nil, source: .unsupported,
                             diagnosis: String(localized: "notes.cover.engineering.unreadableOrTooLarge", defaultValue: "The drawing is too large or unreadable"))
            }
        } catch {
            return .init(image: nil, source: .unsupported,
                         diagnosis: String(localized: "notes.cover.engineering.unreadable", defaultValue: "The drawing is unreadable"))
        }
        if Task.isCancelled { return .init(image: nil, source: .none, diagnosis: "cancelled") }

        // Primary path: the bundled reader (EngineeringPreviewPackage + the
        // packaged viewer.js through LocalPreviewServer) renders the real
        // drawing. All cards share one bounded offscreen host, so no heavy
        // engine is started per card.
        let rendered = await NotesEngineeringCoverRenderer.shared.thumbnail(
            source: source, fileName: fileName, fileExtension: fileExtension, size: size)
        if let image = rendered.image {
            return .init(image: image, source: .engineeringPreview, diagnosis: rendered.diagnosis)
        }
        if Task.isCancelled { return .init(image: nil, source: .none, diagnosis: "cancelled") }

        // Secondary path: a Quick Look content representation for anything the
        // system itself can render (the generator rejects a generic icon).
        let slotID = UUID()
        guard await NotesOfficeThumbnailGate.shared.acquire(id: slotID) else {
            return .init(image: nil, source: .none, diagnosis: "cancelled")
        }
        defer { NotesOfficeThumbnailGate.shared.release() }
        if Task.isCancelled { return .init(image: nil, source: .none, diagnosis: "cancelled") }
        do {
            let staged = try await NotesOfficeThumbnailStaging.stage(source: source, fileExtension: fileExtension)
            defer { NotesOfficeThumbnailStaging.remove(staged) }
            let outcome = await NotesOfficeThumbnailGenerator.thumbnail(url: staged, size: size,
                                                                        fileExtension: fileExtension)
            if Task.isCancelled { return .init(image: nil, source: .none, diagnosis: "cancelled") }
            if let image = outcome.image {
                return .init(image: image, source: .quickLookThumbnail, diagnosis: "quick look")
            }
        } catch is CancellationError {
            return .init(image: nil, source: .none, diagnosis: "cancelled")
        } catch {}
        return .init(image: nil, source: .unsupported,
                     diagnosis: String(localized: "notes.cover.engineering.renderFailed", defaultValue: "Could not render a preview; open the drawing"))
    }

    // MARK: - Native OOXML content summary

    /// Renders a bounded, clearly-labeled content summary from the document's
    /// own parsed text/cells. This is deliberately not a replica of the Office
    /// layout; the card marks it as a summary.
    nonisolated static func contentSummary(snapshot: OfficeDocumentSnapshot, kind: OfficeDocumentKind,
                               size: CGSize) -> UIImage? {
        let fields = Array(snapshot.fields.prefix(maximumSummaryFields))
        guard !fields.isEmpty else { return nil }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let accent = UIColor(red: 0.145, green: 0.388, blue: 0.922, alpha: 1)
            accent.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: 26))
            let header: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 12),
                .foregroundColor: UIColor.white
            ]
            let headerText: String
            switch kind {
            case .word: headerText = String(localized: "notes.cover.summary.word", defaultValue: "Word · Content summary")
            case .workbook: headerText = String(localized: "notes.cover.summary.workbook", defaultValue: "Excel · Content summary")
            case .presentation: headerText = String(localized: "notes.cover.summary.presentation", defaultValue: "PowerPoint · Content summary")
            }
            (headerText as NSString).draw(in: CGRect(x: 10, y: 6, width: size.width - 20, height: 16), withAttributes: header)
            switch kind {
            case .word, .presentation:
                drawParagraphs(fields, origin: CGPoint(x: 14, y: 38), width: size.width - 28,
                               height: size.height - 48)
            case .workbook:
                drawGrid(fields, bounds: CGRect(x: 10, y: 34, width: size.width - 20, height: size.height - 44))
            }
        }
    }

    private nonisolated static func drawParagraphs(_ fields: [OfficeEditableField], origin: CGPoint, width: CGFloat, height: CGFloat) {
        var y = origin.y
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 15),
            .foregroundColor: UIColor.black
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11),
            .foregroundColor: UIColor.darkGray
        ]
        for (index, field) in fields.enumerated() {
            let attributes = index == 0 ? titleAttributes : bodyAttributes
            let lineHeight: CGFloat = index == 0 ? 22 : 16
            guard y + lineHeight <= origin.y + height else { break }
            let text = field.text.replacingOccurrences(of: "\n", with: " ")
            (text as NSString).draw(in: CGRect(x: origin.x, y: y, width: width, height: lineHeight),
                                    withAttributes: attributes)
            y += lineHeight
        }
    }

    /// Excel cells are keyed by reference (A1, B2...). Render the first sheet's
    /// cells on a light grid, tinting the first row so the cover visibly comes
    /// from the workbook data rather than a generic glyph.
    private nonisolated static func drawGrid(_ fields: [OfficeEditableField], bounds: CGRect) {
        let sheet = fields.first?.section ?? ""
        let cells = fields.filter { $0.section == sheet }.prefix(60)
        var parsed: [(column: Int, row: Int, text: String)] = []
        for cell in cells {
            let reference = cell.label.uppercased()
            var column = 0
            var row = 0
            var readingColumn = true
            for scalar in reference.unicodeScalars {
                if readingColumn, scalar.value >= 65, scalar.value <= 90 {
                    column = column * 26 + Int(scalar.value - 64)
                } else if scalar.value >= 48, scalar.value <= 57 {
                    readingColumn = false
                    row = row * 10 + Int(scalar.value - 48)
                } else {
                    readingColumn = true
                }
            }
            guard column > 0, row > 0 else { continue }
            parsed.append((column - 1, row - 1, cell.text))
        }
        guard let maximumColumn = parsed.map(\.column).max(), let maximumRow = parsed.map(\.row).max() else { return }
        let columns = min(maximumColumn + 1, 5)
        let rows = min(maximumRow + 1, 10)
        guard columns > 0, rows > 0 else { return }
        let cellWidth = bounds.width / CGFloat(columns)
        let cellHeight = min(bounds.height / CGFloat(rows), 24)
        let border = UIColor(white: 0.85, alpha: 1)
        let accent = UIColor(red: 0.145, green: 0.388, blue: 0.922, alpha: 1)
        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 10),
            .foregroundColor: UIColor.white
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: UIColor.black
        ]
        for cell in parsed where cell.column < columns && cell.row < rows {
            let rect = CGRect(x: bounds.minX + CGFloat(cell.column) * cellWidth,
                              y: bounds.minY + CGFloat(cell.row) * cellHeight,
                              width: cellWidth, height: cellHeight)
            if cell.row == 0 { accent.setFill() } else { UIColor.white.setFill() }
            UIRectFill(rect)
            border.setStroke()
            UIBezierPath(rect: rect).stroke()
            let attributes = cell.row == 0 ? headerAttributes : bodyAttributes
            (cell.text as NSString).draw(in: rect.insetBy(dx: 4, dy: 4), withAttributes: attributes)
        }
    }
}

#if DEBUG
/// Debug-only acceptance fixture for the Notes library cover UI test.
///
/// It imports genuinely generated Office packages (and one notebook, mind map
/// and bundled DXF drawing) through the same `NoteFileImporter` path used by
/// workspace import, so the library cards are exercised end to end. It is
/// gated on `-ui-testing` plus an explicit launch argument and is idempotent
/// per install, so it never runs in normal use or in other UI tests.
@MainActor
enum NotesOfficeThumbnailFixture {
    static let marker = "封面验收"
    static let launchArgument = "--ui-test-notes-office-thumbnail-fixture"

    static func seedIfRequested(session: NotesSession) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"), arguments.contains(launchArgument),
              let store = session.store else { return }
        let existing = (try? await store.documents(includeTrash: true)) ?? []
        guard !existing.contains(where: { $0.title.hasPrefix(marker) }) else { return }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-cover-fixture-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var drafts: [NoteDocument] = []
        func importOffice(_ fileName: String, build: (URL) throws -> Void) async {
            let url = root.appendingPathComponent(fileName)
            do {
                try build(url)
                drafts.append(try await NoteFileImporter.importFile(url, notebookID: nil, store: store))
            } catch {}
        }

        await importOffice("\(marker)-Word.docx") { url in
            try OfficeDocumentBuilder.createWord(at: url, title: "\(marker) Word 商务周报", paragraphs: [
                "第一段：真实 DOCX 内容封面验收。",
                "Second paragraph: real DOCX content cover.",
                "第三段：缩略图应来自这个包，而不是通用文件图标。"
            ])
        }
        await importOffice("\(marker)-Excel.xlsx") { url in
            try OfficeDocumentBuilder.createWorkbook(at: url, sheets: [.init(name: "封面", rows: [
                ["季度", "收入", "成本"],
                ["Q1", "120", "80"],
                ["Q2", "150", "96"],
                ["Q3", "168", "101"]
            ])])
        }
        await importOffice("\(marker)-PPT.pptx") { url in
            try OfficeDocumentBuilder.createPresentation(at: url, title: "\(marker) 产品路线图", slides: [
                .init(title: "\(marker) 产品路线图", bullets: ["里程碑一", "Milestone 2"]),
                .init(title: "风险", bullets: ["合成内容", "No sensitive data"])
            ])
        }

        var note = NoteDocument(kind: .notebook, notebookID: nil, title: "\(marker) 手写页")
        note.pages[0].elements = [NoteElement(frame: .init(x: 60, y: 80, width: 620, height: 200),
                                              text: "真实手记页封面验收\nHandwritten cover", fontSize: 32)]
        drafts.append(note)

        var map = NoteDocument(kind: .mindMap, notebookID: nil, title: "\(marker) 导图")
        if let rootID = map.nodes.first?.id {
            map.nodes.append(MindMapNode(parentID: rootID, title: "分支 A", order: 0))
            map.nodes.append(MindMapNode(parentID: rootID, title: "分支 B", order: 1))
        }
        drafts.append(map)

        if let sample = Bundle.main.url(forResource: "EngineeringViewers", withExtension: nil)?
            .appendingPathComponent("sample-plate.dxf") {
            let destination = root.appendingPathComponent("\(marker)-图纸.dxf")
            if (try? Data(contentsOf: sample).write(to: destination, options: .atomic)) != nil,
               let draft = try? await NoteFileImporter.importFile(destination, notebookID: nil, store: store) {
                drafts.append(draft)
            }
        }
        if let sample = Bundle.main.url(forResource: "EngineeringViewers", withExtension: nil)?
            .appendingPathComponent("sample-editable.dwg") {
            let destination = root.appendingPathComponent("\(marker)-图纸-DWG.dwg")
            if (try? Data(contentsOf: sample).write(to: destination, options: .atomic)) != nil,
               let draft = try? await NoteFileImporter.importFile(destination, notebookID: nil, store: store) {
                drafts.append(draft)
            }
        }

        for draft in drafts { _ = try? await store.create(draft) }
        try? await session.reload()
    }
}
#endif
#endif
