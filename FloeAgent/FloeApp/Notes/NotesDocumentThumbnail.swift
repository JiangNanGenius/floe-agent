// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit
import Foundation
import QuickLookThumbnailing
import FloeNotes
import PencilKit
import os

/// Bounded in-memory cache for Notes grid thumbnails.
///
/// The key always contains the document id plus the immutable resource id and
/// revision, so a thumbnail can never be shown for a different revision or a
/// different document. Only generated previews (Office Quick Look, rendered
/// note covers) are cached; the cache evicts under a hard cost limit.
@MainActor
private final class NotesDocumentThumbnailCache {
    static let shared = NotesDocumentThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 80
        cache.totalCostLimit = 48 * 1024 * 1024
    }
    func image(for key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    func store(_ image: UIImage, for key: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key as NSString, cost: max(cost, 1))
    }
}

/// One grid/list preview. Notebook and mind map cards keep the existing page
/// rendering; Office cards ask the system Quick Look generator for a real
/// thumbnail; engineering cards never claim a thumbnail and show their icon.
/// No live Office engine is started for a card.
@MainActor
struct NotesDocumentThumbnail: View {
    let document: NoteDocument
    let store: NotesStore?
    @State private var image: UIImage?
    /// The key of the newest load. A cancelled predecessor compares against this
    /// before touching `image`, so it can never clear or overwrite a newer card.
    @State private var currentKey: String?

    private static let thumbnailSize = CGSize(width: 320, height: 420)
    /// A card must not ask Quick Look to decode an arbitrarily large Office file.
    private static let maximumThumbnailSourceBytes = 128 * 1024 * 1024

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                placeholder
            }
        }
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
        VStack(spacing: 12) {
            Image(systemName: symbolName).font(.largeTitle).foregroundStyle(.tint)
            Text(placeholderTitle).font(.caption).lineLimit(3).multilineTextAlignment(.center)
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
        if let cached = NotesDocumentThumbnailCache.shared.image(for: key) {
            image = cached
            return
        }
        image = nil
        guard !Task.isCancelled else { return }
        switch document.kind {
        case .office:
            await loadOfficeThumbnail(key: key)
        case .engineering:
            // The bundled CAD viewer is not a Quick Look generator; claiming a
            // thumbnail here would be false. Keep the icon until the dedicated
            // NotesEngineeringView is opened.
            image = nil
        case .notebook, .mindMap:
            await loadNoteCover(key: key)
        }
    }

    /// Store the pixels under their immutable key, but only publish them when
    /// this task still owns the card. A cancelled predecessor that resumes late
    /// can populate the cache yet can never clear or replace the newer image.
    private func apply(_ value: UIImage?, key: String) {
        if let value { NotesDocumentThumbnailCache.shared.store(value, for: key) }
        guard key == currentKey else { return }
        image = value
    }

    private func loadOfficeThumbnail(key: String) async {
        // Quick Look cannot type an extensionless SHA-256 CAS path, so a copy
        // carrying the validated Office filename extension is staged once and
        // reused by every bounded retry attempt.
        guard let store, let resourceID = document.officeResourceID,
              let fileName = document.officeFileName,
              let fileExtension = NotesOfficeThumbnailStaging.validatedExtension(of: fileName) else {
            apply(nil, key: key)
            return
        }
        do {
            let url = try await store.resourceURL(resourceID)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize,
                  size <= Self.maximumThumbnailSourceBytes else { apply(nil, key: key); return }
            try Task.checkCancellation()
            // The shared slot is acquired BEFORE staging: a staged copy can be
            // up to 128 MiB, so copying must be bounded by the same gate as
            // generation instead of running unbounded for every visible card.
            // One gate slot covers the whole bounded request: cancellation of
            // the card task (scroll-away) cancels the retry loop at once, and
            // the policy caps how long a slot can be held.
            let slotID = UUID()
            guard await NotesOfficeThumbnailGate.shared.acquire(id: slotID) else { return }
            defer { NotesOfficeThumbnailGate.shared.release() }
            try Task.checkCancellation()
            let staged = try await NotesOfficeThumbnailStaging.stage(source: url, fileExtension: fileExtension)
            defer { NotesOfficeThumbnailStaging.remove(staged) }
            let outcome = await NotesOfficeThumbnailGenerator.thumbnail(url: staged, size: Self.thumbnailSize,
                                                                        fileExtension: fileExtension)
            // A card cancelled while Quick Look was working must not publish
            // pixels to a card it no longer owns.
            guard !Task.isCancelled else { return }
            if let image = outcome.image {
                NotesOfficeThumbnailGenerator.logSuccess(fileExtension: fileExtension, attempt: outcome.attempts,
                                                         elapsed: outcome.elapsed)
                apply(image, key: key)
            } else {
                NotesOfficeThumbnailGenerator.logFailure(fileExtension: fileExtension, attempts: outcome.attempts,
                                                         elapsed: outcome.elapsed, outcome: outcome)
                apply(nil, key: key)
            }
        } catch is CancellationError {
        } catch {
            apply(nil, key: key)
        }
    }

    private func loadNoteCover(key: String) async {
        guard let store, let page = document.pages.first else { return }
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
            apply(rendered, key: key)
        } catch {
            apply(nil, key: key)
        }
    }
}

/// Bounded retry policy for one Office thumbnail card. Every value is finite:
/// a card can never poll Quick Look forever, and cancellation always wins.
struct NotesOfficeThumbnailPolicy: Sendable {
    /// Hard cap on a single generator request.
    var perAttemptTimeout: Duration = .seconds(15)
    /// Total attempts including the first; attempts two and three may recover
    /// a transient first-attempt failure (e.g. a cold-start generator launch
    /// race — still a hypothesis here, not yet proven by a green cloud run).
    var maxAttempts: Int = 3
    /// Absolute wall-clock budget for the whole card request.
    var totalDeadline: Duration = .seconds(45)
    var initialBackoff: Duration = .milliseconds(500)
    var maximumBackoff: Duration = .seconds(2)
}

/// The single Office thumbnail request path shared by the product grid and
/// the NativeNotes qualification tests. One bounded request at a time,
/// explicit generator cancellation on timeout/cancel, and structured
/// diagnostics (attempt, elapsed, sanitized error domain+code) for every
/// failure so a cloud run can be diagnosed from logs alone. Product logs
/// never carry document file names, staged paths or raw error text; the full
/// diagnosis stays in the returned outcome for local test triage only. A
/// failed request is never cached; callers decide how to retry within
/// `NotesOfficeThumbnailPolicy`.
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
    }

    /// The product retry policy, shared with the qualification tests so both
    /// exercise identical bounded recovery behaviour for transient first
    /// attempts (cold-start launch races remain a hypothesis until a green
    /// cloud run confirms them).
    static let cardPolicy = NotesOfficeThumbnailPolicy()

    /// Bounded retry over `request`: at most `policy.maxAttempts` tries, an
    /// absolute `policy.totalDeadline`, cancellable backoff between attempts
    /// (capped so the sleep can never push past the deadline), and no attempt
    /// ever started after cancellation. `request` defaults to the shared
    /// Quick Look path; tests may inject a controlled request to exercise
    /// in-flight cancellation without a generator. `fileExtension` (already
    /// validated by staging) is the only document detail that labels logs.
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
            if let image = outcome.image {
                return CardOutcome(image: image, attempts: attempt,
                                   diagnosis: outcome.diagnosis, elapsed: elapsed())
            }
            last = outcome
            logRetry(fileExtension: fileExtension, attempt: attempt, maxAttempts: policy.maxAttempts,
                     elapsed: elapsed(), outcome: outcome)
            guard attempt < policy.maxAttempts, elapsed() < policy.totalDeadline else { break }
            // Cancellable backoff clamped to the remaining total budget, so a
            // sleep can never exceed the absolute deadline; cancellation
            // throws at once and the loop condition exits without another
            // request.
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
                    let image = representation?.uiImage
                    let nsError = error.map { $0 as NSError }
                    let diagnosis: String?
                    if let error { diagnosis = String(describing: error) }
                    else if image == nil { diagnosis = "empty representation" }
                    else { diagnosis = nil }
                    Task { @MainActor in
                        state.finish(image: image, diagnosis: diagnosis, timedOut: false,
                                     errorDomain: nsError?.domain, errorCode: nsError?.code)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in state.cancel(reason: "task cancelled") }
        }
        return AttemptOutcome(image: result.image, diagnosis: result.diagnosis, timedOut: result.timedOut,
                              elapsed: start.duration(to: ContinuousClock.now),
                              errorDomain: result.errorDomain, errorCode: result.errorCode)
    }

    /// Logs carry only the validated extension, attempt, elapsed time and a
    /// non-sensitive failure category (timeout, empty representation, or the
    /// numeric error domain+code) — never a document file name, staged path
    /// or raw error description.
    private static func category(of outcome: AttemptOutcome) -> String {
        if outcome.diagnosis == "task cancelled" { return "cancelled" }
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

    static func logFailure(fileExtension: String, attempts: Int, elapsed: Duration, outcome: CardOutcome) {
        let last = AttemptOutcome(image: nil, diagnosis: outcome.diagnosis, timedOut: outcome.timedOut,
                                  elapsed: outcome.elapsed, errorDomain: outcome.errorDomain,
                                  errorCode: outcome.errorCode)
        logger.error("[thumbnail] .\(fileExtension, privacy: .public) gave up after \(attempts, privacy: .public) attempt(s), \(elapsed, privacy: .public)s total; last: \(category(of: last), privacy: .public)")
    }
}

/// Quick Look keys off the file extension, while a Notes resource is stored at
/// an extensionless SHA-256 CAS path. Stage a uniquely scoped copy whose name
/// carries the validated Office extension; callers remove the whole directory
/// once the request settles or is cancelled.
private enum NotesOfficeThumbnailStaging {
    static let supportedExtensions: Set<String> = [
        "docx", "doc", "odt", "rtf", "xlsx", "xls", "ods", "pptx", "ppt", "odp"
    ]

    /// The same basename/extension rule the document model enforces, repeated so
    /// a thumbnail request never stages an unexpected or traversing name.
    static func validatedExtension(of fileName: String) -> String? {
        guard !fileName.isEmpty, fileName == (fileName as NSString).lastPathComponent else { return nil }
        let ext = (fileName as NSString).pathExtension.lowercased()
        return supportedExtensions.contains(ext) ? ext : nil
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

/// Process-wide bound on concurrent Quick Look Office generation. A scrolling
/// grid can spawn many cards at once; at most two previews decode a source file
/// at a time and the rest wait for a slot. Cancelling a queued card resumes it
/// at once without ever handing it a slot.
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
                // Registration and slot allocation must be one serialized step:
                // a release between them would otherwise strand the waiter.
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
                errorDomain: String? = nil, errorCode: Int? = nil) {
        guard !finished else { return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: NotesOfficeThumbnailGenerator.AttemptOutcome(image: image,
                                                       diagnosis: diagnosis ?? "request settled without a result",
                                                       timedOut: timedOut, elapsed: .zero,
                                                       errorDomain: errorDomain, errorCode: errorCode))
    }

    func cancel(reason: String) {
        guard !finished else { return }
        QLThumbnailGenerator.shared.cancel(request)
        finish(image: nil, diagnosis: reason, timedOut: reason == "per-attempt timeout")
    }
}
#endif
