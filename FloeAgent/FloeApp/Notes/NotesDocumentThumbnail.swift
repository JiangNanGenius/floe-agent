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

/// Bounded, redacted failure identity for one Office cover render.
///
/// It carries only counters, booleans and the numeric Quick Look error
/// identity. It never carries a file name, staged path, document content or a
/// raw error description, so it is safe to attach to acceptance artifacts and
/// to expose through the UI-test accessibility value. Normal VoiceOver output
/// does not include it (`-ui-testing` only).
struct NotesDocumentCoverDiagnostics: Sendable, Equatable {
    /// The last relevant generator/fallback stage. `.quickLook` is retained
    /// after a successful system thumbnail or a successful summary fallback;
    /// the outcome source distinguishes those successes. Other cases name the
    /// first failing native fallback step, so a size guard is never confused
    /// with a parse or draw failure.
    enum FallbackStage: String, Sendable {
        case quickLook
        case staging
        case unsupportedType
        case sizeLimit
        case inspect
        case render
    }

    var quickLookAttempts: Int = 0
    var quickLookTimedOut: Bool = false
    var quickLookErrorDomain: String?
    var quickLookErrorCode: Int?
    var quickLookWasIconFallback: Bool = false
    var fallbackStage: FallbackStage = .quickLook

    /// The only error domains a cover artifact may name. Quick Look and
    /// Foundation failures use these; every other domain is reported as the
    /// literal `other` so an unexpected error can never inject a path, account
    /// name or other identifying text into an artifact. A character filter
    /// alone is not enough: an all-alphanumeric hostile domain would still be
    /// identifying.
    static let knownErrorDomains: Set<String> = [
        "QLThumbnailErrorDomain",
        "QLThumbnailGenerationErrorDomain",
        "NSCocoaErrorDomain",
        "NSPOSIXErrorDomain",
        "NSURLErrorDomain",
        "NSOSStatusErrorDomain",
    ]

    static func boundedDomain(_ domain: String?) -> String? {
        guard let domain, !domain.isEmpty else { return nil }
        return knownErrorDomains.contains(domain) ? domain : "other"
    }

    var summary: String {
        var parts = ["attempts=\(quickLookAttempts)", "timedOut=\(quickLookTimedOut)"]
        if let quickLookErrorDomain { parts.append("domain=\(quickLookErrorDomain)") }
        if let quickLookErrorCode { parts.append("code=\(quickLookErrorCode)") }
        if quickLookWasIconFallback { parts.append("icon=true") }
        parts.append("fallback=\(fallbackStage.rawValue)")
        return parts.joined(separator: " ")
    }
}

/// The settled result of one cover render.
struct NotesDocumentCoverOutcome: Sendable {
    var image: UIImage?
    var source: NotesDocumentCoverSource
    var diagnosis: String
    /// Present for Office covers. Bounded and redacted; see
    /// `NotesDocumentCoverDiagnostics`.
    var diagnostics: NotesDocumentCoverDiagnostics? = nil
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
    var onSource: ((NotesDocumentCoverSource, Int, String) -> Void)?
    @State private var image: UIImage?
    @State private var source: NotesDocumentCoverSource = .none
    @State private var unsupportedDetail: String?
    @State private var diagnostics: NotesDocumentCoverDiagnostics?
    /// The key of the newest load. A cancelled predecessor compares against this
    /// before touching `image`, so it can never clear or overwrite a newer card.
    @State private var currentKey: String?

    private static let thumbnailSize = CGSize(width: 320, height: 420)
    /// A card must not ask Quick Look to decode an arbitrarily large file.
    private static let maximumThumbnailSourceBytes = 128 * 1024 * 1024

    init(document: NoteDocument, store: NotesStore?,
         onSource: ((NotesDocumentCoverSource, Int, String) -> Void)? = nil) {
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
        .accessibilityValue(accessibilityCoverValue)
        .task(id: thumbnailKey) { await load() }
    }

    /// Production accessibility keeps the plain cover source. Under UI testing
    /// the bounded, redacted generator identity is appended so an acceptance
    /// artifact can name the exact failure stage (attempts, timeout, numeric
    /// error identity, fallback stage) without any path, file name or content.
    /// The `badge=summary` marker is the test-visible identity of the visible
    /// "Summary" capsule: it is appended only when this card is actually
    /// publishing `.officeContentSummary`, so an acceptance run can reject an
    /// unlabelled summary instead of trusting the source string alone.
    private var accessibilityCoverValue: String {
        guard ProcessInfo.processInfo.arguments.contains("-ui-testing") else { return source.rawValue }
        let badge = source == .officeContentSummary ? "; badge=summary" : ""
        guard let diagnostics else { return source.rawValue + badge }
        return "\(source.rawValue)\(badge); \(diagnostics.summary)"
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

    /// Load one cover. For a modern Office document the service publishes a
    /// real content summary as a provisional first paint before the bounded
    /// Quick Look request settles, so a card never waits out the 45 s Quick
    /// Look budget to show document content. The final outcome replaces it and
    /// is the only value cached; a cancelled or superseded task can never apply
    /// either phase to a newer card (the key guard below).
    private func load() async {
        let key = thumbnailKey
        currentKey = key
        if let cached = NotesDocumentThumbnailCache.shared.entry(for: key) {
            image = cached.image
            source = cached.source
            unsupportedDetail = nil
            diagnostics = nil
            onSource?(cached.source, document.revision, accessibilityCoverValue)
            return
        }
        image = nil
        source = .none
        unsupportedDetail = nil
        diagnostics = nil
        guard !Task.isCancelled else { return }
        let outcome = await NotesDocumentCoverService.render(document: document, store: store,
                                                             size: Self.thumbnailSize,
                                                             maximumSourceBytes: Self.maximumThumbnailSourceBytes,
                                                             onFirstPaint: { update in
            applyFirstPaint(update, key: key)
        })
        guard !Task.isCancelled else { return }
        if let value = outcome.image {
            NotesDocumentThumbnailCache.shared.store(.init(image: value, source: outcome.source), for: key)
        }
        apply(outcome, key: key)
    }

    /// Publish the service's provisional content-summary first paint. It is
    /// never cached, so the settled Quick Look upgrade can still land for this
    /// revision; a stale revision (key mismatch) or a non-content phase is
    /// dropped before it can touch the card.
    private func applyFirstPaint(_ outcome: NotesDocumentCoverOutcome, key: String) {
        guard key == currentKey, outcome.source == .officeContentSummary,
              let value = outcome.image else { return }
        image = value
        source = outcome.source
        diagnostics = nil
        unsupportedDetail = nil
        onSource?(outcome.source, document.revision, accessibilityCoverValue)
    }

    /// Publish the settled cover only when this task still owns the card. A
    /// cancelled predecessor that resumes late can populate the cache yet can
    /// never clear or replace the newer card's state.
    private func apply(_ outcome: NotesDocumentCoverOutcome, key: String) {
        guard key == currentKey else { return }
        image = outcome.image
        source = outcome.source
        diagnostics = outcome.diagnostics
        unsupportedDetail = outcome.source == .unsupported ? outcome.diagnosis : nil
        onSource?(outcome.source, document.revision, accessibilityCoverValue)
    }
}

/// Bounded policy for one Office cover resource. Every value is finite: a card
/// can never poll Quick Look forever, and cancellation always wins.
///
/// A request that is merely *late* is not a failure to restart. In the build 185
/// full-App diagnostic, seven app-side 15 s timeouts produced seven late host
/// error replies (`QLExtensionHostContextThumbnailOperation Code=1` /
/// `QLThumbnailErrorDomain Code=0`), three of them explicitly logged more than
/// 60 s after the request started — the Office Quick Look extension host was
/// still holding cancelled work rather than releasing it. One request therefore
/// holds the remaining total budget and is cancelled at most once, at the total
/// deadline. A retry only starts after the previous request has *settled* (its
/// callback was delivered), never while it is still outstanding. This does not
/// claim the host's exact congestion behaviour; it only removes app-side
/// cancel/restart multiplication while the host is busy.
struct NotesOfficeThumbnailPolicy: Sendable {
    /// Total attempts including the first. An attempt after the first recovers
    /// a settled generator error only; an outstanding request is never
    /// duplicated.
    var maxAttempts: Int = 3
    /// Absolute wall-clock budget for one resource, covering every attempt and
    /// backoff. One generator request holds the remaining budget and is
    /// cancelled exactly once at this deadline.
    var totalDeadline: Duration = .seconds(45)
    var initialBackoff: Duration = .milliseconds(500)
    var maximumBackoff: Duration = .seconds(2)
}

/// The settled signal of one generator request attempt. It is Quick Look-free
/// so the bounded lifecycle below can be driven deterministically in tests
/// without constructing a `QLThumbnailRepresentation`.
enum NotesQuickLookAttemptSignal: Sendable {
    case content(image: UIImage, diagnosis: String?)
    case icon(diagnosis: String)
    case failure(diagnosis: String, domain: String?, code: Int?)
}

/// Deterministic transport seam for exactly one generator request. The product
/// driver wraps `QLThumbnailGenerator`; a test driver can hold the completion,
/// reply late, or never reply, and count cancels, all without a simulator
/// generator. `start` delivers its completion on the main actor at most once.
struct NotesQuickLookRequestDriver {
    var start: (@escaping @MainActor (NotesQuickLookAttemptSignal) -> Void) -> Void
    var cancel: @MainActor () -> Void
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

    /// One bounded card request over `request`: at most `policy.maxAttempts`
    /// tries, an absolute `policy.totalDeadline`, cancellable backoff between
    /// settled failures, and no attempt ever started after cancellation. A
    /// request that times out (its own deadline cancelled it exactly once) is
    /// terminal: it is never restarted while the shared extension host may
    /// still hold it. A generic `.icon` representation is terminal too: there
    /// is no point retrying an unsupported generator, and it must never be
    /// returned as a cover. Per-resource coalescing is owned by
    /// `NotesOfficeCoverFlights`, above the shared host slot, so this function
    /// always performs exactly the one bounded request its caller asked for.
    static func thumbnail(url: URL, size: CGSize, fileExtension: String = "",
                          policy: NotesOfficeThumbnailPolicy = NotesOfficeThumbnailGenerator.cardPolicy,
                          request: (@MainActor (URL, CGSize, Duration) async -> AttemptOutcome)? = nil) async -> CardOutcome {
        // `request` is an explicit per-call seam: a caller may inject a
        // deterministic generator (e.g. a forced failure or a held callback),
        // and parallel cards never observe each other's request. There is no
        // process-global mock for the generator itself.
        await boundedOutcome(url: url, size: size, fileExtension: fileExtension,
                             policy: policy, request: request)
    }

    /// The bounded attempt loop. A timeout is terminal (the outstanding request
    /// was already cancelled exactly once by its own deadline); only a settled,
    /// non-timeout failure may retry, so the host never sees a cancel/restart
    /// storm.
    private static func boundedOutcome(url: URL, size: CGSize, fileExtension: String,
                                       policy: NotesOfficeThumbnailPolicy,
                                       request: (@MainActor (URL, CGSize, Duration) async -> AttemptOutcome)?) async -> CardOutcome {
        let start = ContinuousClock.now
        func elapsed() -> Duration { start.duration(to: ContinuousClock.now) }
        let perform = request ?? requestThumbnail
        var attempt = 0
        var backoff = policy.initialBackoff
        var last = AttemptOutcome(image: nil, diagnosis: "no attempt ran", timedOut: false, elapsed: .zero)
        while attempt < policy.maxAttempts,
              !Task.isCancelled,
              elapsed() < policy.totalDeadline {
            attempt += 1
            // One request holds the remaining total budget. There is no
            // per-attempt cancel/restart: the request's own bounded deadline
            // settles it, and a late callback after that is dropped by the
            // request state.
            let remaining = policy.totalDeadline - elapsed()
            let outcome = await perform(url, size, remaining)
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
            // A timed-out request must not be restarted: the extension host may
            // still be working on it even though the app-side deadline passed.
            guard !outcome.timedOut,
                  attempt < policy.maxAttempts,
                  elapsed() < policy.totalDeadline else { break }
            let remainingAfterAttempt = policy.totalDeadline - elapsed()
            try? await Task.sleep(for: min(backoff, remainingAfterAttempt))
            backoff = min(backoff * 2, policy.maximumBackoff)
        }
        return CardOutcome(image: nil, attempts: attempt, diagnosis: last.diagnosis,
                           elapsed: elapsed(), timedOut: last.timedOut,
                           errorDomain: last.errorDomain, errorCode: last.errorCode)
    }

    /// One bounded and cancellable Quick Look request: a single hard deadline,
    /// no polling, explicit cancellation of the generator request exactly once,
    /// and a guarded single resume shared by the generator callback, the
    /// deadline and cancellation. The product adapter rejects a generic `.icon`
    /// representation before it can reach the cover path.
    static func requestThumbnail(url: URL, size: CGSize, timeout: Duration) async -> AttemptOutcome {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 1, representationTypes: .thumbnail)
        let driver = NotesQuickLookRequestDriver(
            start: { completion in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
                    let nsError = error.map { $0 as NSError }
                    // A generic file-type icon is not document content. Reject
                    // it explicitly so it can never be cached or shown as a
                    // thumbnail, and so the bounded loop does not waste retries.
                    let signal: NotesQuickLookAttemptSignal
                    if let representation, !isContentRepresentation(representation.type) {
                        signal = .icon(diagnosis: "generic icon representation")
                    } else if let image = representation?.uiImage {
                        signal = .content(image: image, diagnosis: nil)
                    } else if let error {
                        signal = .failure(diagnosis: String(describing: error),
                                          domain: nsError?.domain, code: nsError?.code)
                    } else {
                        signal = .failure(diagnosis: "empty representation", domain: nil, code: nil)
                    }
                    Task { @MainActor in completion(signal) }
                }
            },
            cancel: { QLThumbnailGenerator.shared.cancel(request) })
        return await drive(driver, timeout: timeout)
    }

    /// Runs the exact product request lifecycle for one injected driver: attach
    /// first, start once, settle once on the first callback or at `timeout`, and
    /// cancel the outstanding request at most once. A late callback after the
    /// request settled is dropped by the single-resume state, never delivered
    /// twice and never applied to a newer cover.
    static func drive(_ driver: NotesQuickLookRequestDriver, timeout: Duration) async -> AttemptOutcome {
        let start = ContinuousClock.now
        let state = NotesThumbnailRequestState()
        let deadlineTask = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            state.cancel(reason: "request deadline", timedOut: true)
        }
        defer { deadlineTask.cancel() }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AttemptOutcome, Never>) in
                guard state.attach(continuation) else { return }
                guard !Task.isCancelled else {
                    // The owner went away before the request could start:
                    // settle without starting (and therefore without
                    // cancelling) a generator request.
                    state.cancel(reason: "task cancelled")
                    return
                }
                state.arm(driver.cancel)
                driver.start { signal in state.finish(signal) }
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

/// Service-owned single-flight registry for one Office cover resource. The
/// whole resource operation — shared-host slot, staging, the one bounded Quick
/// Look request and the native fallback — is owned by one service task, so a
/// second card for the same revision joins that operation *before* it waits for
/// the shared host slot. (A generator-level wrap would sit behind the gate: the
/// second card would wait outside the shared request and never join it.) The
/// staged copy is created and removed inside the shared operation, so a
/// cancelled first caller can never delete a copy another waiter needs. The
/// task is cancelled only when its last waiter cancels, so one scrolling card
/// can never cancel work another card still needs. Entries are removed as soon
/// as they settle; beyond `maximumEntries` a new resource runs without
/// coalescing rather than growing the registry without bound.
///
/// The registry also owns the progressive first paint: the shared operation
/// publishes one provisional content summary to every waiter that is joined at
/// that moment, and remembers it so a waiter joining later receives the same
/// image without re-reading or re-rendering the resource. A first paint is
/// only ever broadcast through the exact `Flight` instance that produced it,
/// so a superseded or cancelled operation whose task outlives its registry
/// entry can never deliver into a newer flight for the same key.
@MainActor
final class NotesOfficeCoverFlights {
    static let shared = NotesOfficeCoverFlights()

    /// Hard cap on tracked resources. It is only a memory bound: the shared
    /// Quick Look gate still bounds how many of them can actually run.
    static let maximumEntries = 16

    private final class Flight {
        var task: Task<NotesDocumentCoverOutcome, Never>?
        var waiters: Set<UUID> = []
        /// Settled provisional summary, remembered for late joiners.
        var firstPaint: NotesDocumentCoverOutcome?
        var firstPaintWaiters: [(UUID, @MainActor (NotesDocumentCoverOutcome) -> Void)] = []
    }

    private var flights: [String: Flight] = [:]

    /// Runs one shared resource operation and delivers its optional first paint
    /// to every waiter. `perform` receives an emit closure it may call at most
    /// once, before it returns the final outcome.
    func outcome(key: String,
                 onFirstPaint: (@MainActor (NotesDocumentCoverOutcome) -> Void)? = nil,
                 perform: @escaping @MainActor (@escaping @MainActor (NotesDocumentCoverOutcome) -> Void) async -> NotesDocumentCoverOutcome) async -> NotesDocumentCoverOutcome {
        let token = UUID()
        let flight: Flight
        if let existing = flights[key] {
            flight = existing
        } else if flights.count < Self.maximumEntries {
            flight = Flight()
            flight.task = Task { @MainActor [weak self] in
                await perform { outcome in
                    self?.publishFirstPaint(key: key, flight: flight, outcome: outcome)
                }
            }
            flights[key] = flight
        } else {
            // Bounded fallback: no coalescing beyond the cap.
            return await perform { outcome in onFirstPaint?(outcome) }
        }
        flight.waiters.insert(token)
        if let firstPaint = flight.firstPaint {
            onFirstPaint?(firstPaint)
        } else if let onFirstPaint {
            flight.firstPaintWaiters.append((token, onFirstPaint))
        }
        let task = flight.task
        let value = await withTaskCancellationHandler {
            await task?.value ?? NotesDocumentCoverOutcome(image: nil, source: .none, diagnosis: "cancelled")
        } onCancel: {
            Task { @MainActor in self.leave(key: key, token: token) }
        }
        leave(key: key, token: token)
        return value
    }

    /// Test-visible observability for the service-path coalescing check: the
    /// number of waiters currently joined to one resource flight.
    func waiterCount(forKey key: String) -> Int {
        flights[key]?.waiters.count ?? 0
    }

    /// Broadcasts the provisional first paint of `flight` exactly once. The
    /// identity check is what stops an old operation (whose entry was already
    /// removed and replaced) from writing into a newer flight for the same key.
    private func publishFirstPaint(key: String, flight: Flight, outcome: NotesDocumentCoverOutcome) {
        guard flights[key] === flight, flight.firstPaint == nil else { return }
        flight.firstPaint = outcome
        let waiters = flight.firstPaintWaiters
        flight.firstPaintWaiters.removeAll()
        for (_, deliver) in waiters { deliver(outcome) }
    }

    /// Removes one waiter; when the last waiter leaves, the shared request is
    /// cancelled (at most once) and the entry is dropped. Idempotent: the
    /// normal path and the cancellation handler both call it. A waiter that
    /// leaves before the first paint is never delivered it afterwards.
    private func leave(key: String, token: UUID) {
        guard let flight = flights[key], flight.waiters.remove(token) != nil else { return }
        flight.firstPaintWaiters.removeAll { $0.0 == token }
        if flight.waiters.isEmpty {
            flight.task?.cancel()
            flights[key] = nil
        }
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

/// Process-wide bound on concurrent Office cover work. A scrolling grid can
/// spawn many cards at once, and every card contends for the same system Office
/// Quick Look extension host. In the build 185 full-App diagnostic one card
/// rendered on a second attempt while a concurrent card timed out all three
/// attempts (the host may serialize, or resources/system contention may have
/// starved it; the exact cause is not proven). The host slot is therefore one at
/// a time: a queued card's own deadline does not start until it owns the slot,
/// so serialization bounds concurrency without consuming another card's budget.
/// Cancelling a queued card resumes it at once without ever handing it a slot.
/// Engineering's secondary Quick Look fallback shares the same slot (it only
/// runs after the bundled viewer fails), so mixed CAD/Office work is serialized
/// first-in, first-out and cannot multiply host requests; each owner's own
/// deadline starts only after it holds the slot.
@MainActor
final class NotesOfficeThumbnailGate {
    static let shared = NotesOfficeThumbnailGate(limit: 1)
    /// Bounds the transient staged copy, the bounded OOXML read and the render
    /// of the progressive summary phase. Quick Look still owns `shared`; this
    /// slot exists only because the summary must not wait behind a hung system
    /// request, so the copy and the bounded OOXML read get their own small
    /// limit instead of the host slot. The slot is held for exactly the summary
    /// phase: the staged copy is removed and the slot released before the
    /// operation waits for the shared host slot, so one card's system request
    /// can never delay another card's first paint. Two slots bound the
    /// simultaneous summary copies (and their parsed snapshots) to two; the
    /// single host slot bounds the Quick Look copy to one.
    static let summary = NotesOfficeThumbnailGate(limit: 2)
    private let limit: Int
    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []

    /// Test-visible occupancy of the slots currently held.
    var activeCount: Int { active }
    /// Test-visible occupancy of the acquisitions currently queued.
    var waiterCount: Int { waiters.count }

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

/// Main-actor single-resume state shared by the generator callback, the bounded
/// deadline and the owner's cancellation. Registration is atomic with respect
/// to cancellation, so a cancelled request can never start afterwards. It is
/// Quick Look-free so the exact product lifecycle (including a late callback
/// after a settle) is directly testable with a deterministic driver.
@MainActor
final class NotesThumbnailRequestState {
    private var continuation: CheckedContinuation<NotesOfficeThumbnailGenerator.AttemptOutcome, Never>?
    private var cancelOutstanding: (@MainActor () -> Void)?
    private var finished = false

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

    /// Arms the one-shot cancellation of the outstanding generator request.
    /// It must be armed only immediately before the request starts, so a
    /// request that was never started is never cancelled.
    func arm(_ cancelOutstanding: @escaping @MainActor () -> Void) {
        guard !finished else { return }
        self.cancelOutstanding = cancelOutstanding
    }

    /// Settles the request once from a generator callback. A callback that
    /// arrives after the request already settled is dropped here, so a late
    /// reply can never resume the continuation twice or touch a newer cover.
    func finish(_ signal: NotesQuickLookAttemptSignal) {
        guard !finished else { return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        cancelOutstanding = nil
        switch signal {
        case .content(let image, let diagnosis):
            continuation?.resume(returning: NotesOfficeThumbnailGenerator.AttemptOutcome(
                image: image, diagnosis: diagnosis ?? "content representation",
                timedOut: false, elapsed: .zero))
        case .icon(let diagnosis):
            continuation?.resume(returning: NotesOfficeThumbnailGenerator.AttemptOutcome(
                image: nil, diagnosis: diagnosis, timedOut: false, elapsed: .zero,
                isIconFallback: true))
        case .failure(let diagnosis, let domain, let code):
            continuation?.resume(returning: NotesOfficeThumbnailGenerator.AttemptOutcome(
                image: nil, diagnosis: diagnosis, timedOut: false, elapsed: .zero,
                errorDomain: domain, errorCode: code))
        }
    }

    func cancel(reason: String, timedOut: Bool = false) {
        guard !finished else { return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        let cancelOutstanding = self.cancelOutstanding
        self.cancelOutstanding = nil
        cancelOutstanding?()
        continuation?.resume(returning: NotesOfficeThumbnailGenerator.AttemptOutcome(
            image: nil, diagnosis: reason, timedOut: timedOut, elapsed: .zero))
    }
}

/// One bounded, cancellable cover render for any supported `NoteDocument`.
/// Every kind has a real source: modern Office documents publish a bounded
/// native OOXML content summary first (labeled `.officeContentSummary`) and
/// upgrade to the system Quick Look thumbnail when it settles, while legacy
/// Office formats keep the original Quick Look-first path. Notebooks render
/// their first page; mind maps render their node tree; engineering drawings
/// render through the bundled viewer and only fall back to Quick Look if the
/// bundled viewer cannot paint its own geometry. When no real source exists the
/// outcome is explicitly `.unsupported` with a diagnosis — never an icon
/// pretending to be content.
@MainActor
enum NotesDocumentCoverService {
    nonisolated static let maximumSummaryFields = 240
    /// The native OOXML summary is a fallback; parsing a huge package in the UI
    /// process is never worth it, so it is capped well below the Quick Look
    /// bound and always runs off the main actor.
    static let maximumSummarySourceBytes = 48 * 1024 * 1024

    /// One cover render per document. `request` is an optional per-call Quick
    /// Look generator seam: nil (the product default) uses the real system
    /// generator. It exists so a qualification test can force the "no system
    /// content" branch for one render without a process-global mock that would
    /// contaminate parallel cards.
    ///
    /// `onFirstPaint` receives the provisional native content summary for a
    /// modern Office document before the bounded Quick Look request settles, so
    /// a card shows real document content instead of waiting out the 45 s
    /// system budget. It is a labeled `.officeContentSummary` and never a
    /// substitute for the settled source: the returned outcome is still exactly
    /// `.quickLookThumbnail` or `.officeContentSummary`, and an icon/blank can
    /// never be published through either phase.
    static func render(document: NoteDocument, store: NotesStore?, size: CGSize,
                       maximumSourceBytes: Int,
                       request: (@MainActor (URL, CGSize, Duration) async -> NotesOfficeThumbnailGenerator.AttemptOutcome)? = nil,
                       onFirstPaint: (@MainActor (NotesDocumentCoverOutcome) -> Void)? = nil) async -> NotesDocumentCoverOutcome {
        guard let store else {
            return .init(image: nil, source: .unsupported,
                         diagnosis: String(localized: "notes.cover.error.storeUnavailable", defaultValue: "Notes storage is not ready"))
        }
        switch document.kind {
        case .office:
            return await officeCover(document: document, store: store, size: size,
                                     maximumSourceBytes: maximumSourceBytes, request: request,
                                     onFirstPaint: onFirstPaint)
        case .notebook:
            return await notePageCover(document: document, store: store)
        case .mindMap:
            return mindMapCover(document: document, size: size)
        case .engineering:
            return await engineeringCover(document: document, store: store, size: size, maximumSourceBytes: maximumSourceBytes)
        }
    }

    // MARK: - Office

    /// One Office cover per resource. Validation and the single-flight key are
    /// computed first; the whole resource operation (staging, the provisional
    /// summary, the shared host slot, Quick Look, native fallback) then runs
    /// once inside `NotesOfficeCoverFlights`, so a second concurrent card for
    /// the same resource joins that operation *before* it can wait for the host
    /// slot and also receives its provisional summary without re-reading the
    /// package.
    private static func officeCover(document: NoteDocument, store: NotesStore, size: CGSize,
                                    maximumSourceBytes: Int,
                                    request: (@MainActor (URL, CGSize, Duration) async -> NotesOfficeThumbnailGenerator.AttemptOutcome)? = nil,
                                    onFirstPaint: (@MainActor (NotesDocumentCoverOutcome) -> Void)? = nil) async -> NotesDocumentCoverOutcome {
        guard let resourceID = document.officeResourceID, let fileName = document.officeFileName,
              let fileExtension = NotesOfficeThumbnailStaging.validatedExtension(of: fileName) else {
            return .init(image: nil, source: .unsupported,
                         diagnosis: String(localized: "notes.cover.office.invalidResource", defaultValue: "The Office file reference is invalid"))
        }
        let key = officeResourceKey(document: document, store: store, fileExtension: fileExtension,
                                    size: size, maximumSourceBytes: maximumSourceBytes)
        return await NotesOfficeCoverFlights.shared.outcome(key: key, onFirstPaint: onFirstPaint) { emitFirstPaint in
            await renderOfficeResource(store: store, resourceID: resourceID,
                                       fileExtension: fileExtension, size: size,
                                       maximumSourceBytes: maximumSourceBytes, request: request,
                                       emitFirstPaint: emitFirstPaint)
        }
    }

    /// The single-flight identity of one Office cover resource. It binds the
    /// owning store, document id, immutable resource id, revision, validated
    /// extension, requested cover size and the caller's source-byte bound, so
    /// no call site can ever share a cover across stores, revisions, sizes or
    /// caps. Internal so the service-path coalescing test can assert the exact
    /// shared flight.
    static func officeResourceKey(document: NoteDocument, store: NotesStore, fileExtension: String,
                                  size: CGSize, maximumSourceBytes: Int) -> String {
        "\(ObjectIdentifier(store)):\(document.id.uuidString):\(document.officeResourceID?.uuidString ?? "none"):\(document.revision):\(fileExtension):\(Int(size.width))x\(Int(size.height)):\(maximumSourceBytes)"
    }

    /// The exact modern OOXML formats the native summary understands; every
    /// other extension keeps the original Quick Look-first path.
    static func summaryDocumentKind(for fileExtension: String) -> OfficeDocumentKind? {
        switch fileExtension {
        case "docx": .word
        case "xlsx": .workbook
        case "pptx": .presentation
        default: nil
        }
    }

    /// One resource operation, called exactly once per shared flight. The
    /// operation — and not an individual caller — owns every staged copy, so a
    /// cancelled first waiter can never delete a copy another waiter needs. A
    /// modern OOXML package within the native summary bound takes the
    /// two-phase progressive path (gated summary copy, then gated Quick Look
    /// copy); everything else keeps the original Quick Look-first path. The
    /// over-cap, non-coalesced fallback in `NotesOfficeCoverFlights` runs this
    /// same body, so its copies and requests are bounded by the same gates.
    private static func renderOfficeResource(store: NotesStore, resourceID: UUID,
                                             fileExtension: String, size: CGSize,
                                             maximumSourceBytes: Int,
                                             request: (@MainActor (URL, CGSize, Duration) async -> NotesOfficeThumbnailGenerator.AttemptOutcome)? = nil,
                                             emitFirstPaint: @escaping @MainActor (NotesDocumentCoverOutcome) -> Void) async -> NotesDocumentCoverOutcome {
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

        if summaryDocumentKind(for: fileExtension) != nil, sourceBytes <= maximumSummarySourceBytes {
            return await renderProgressiveResource(source: source, fileExtension: fileExtension,
                                                   size: size, request: request,
                                                   emitFirstPaint: emitFirstPaint)
        }
        return await renderQuickLookFirstResource(source: source, fileExtension: fileExtension,
                                                  size: size, sourceBytes: sourceBytes, request: request)
    }

    /// Progressive path for a modern OOXML package inside the native summary
    /// bound. It has two bounded phases, each owning its own staged copy for
    /// exactly its own scope:
    ///
    ///  * the summary phase runs entirely under the two-slot
    ///    `NotesOfficeThumbnailGate.summary`; it stages one copy, parses and
    ///    renders the bounded summary, deletes the copy and releases the slot
    ///    before returning. At most two summary copies (and two parsed
    ///    snapshots) exist, and neither survives into the Quick Look wait, so
    ///    the summary never holds a slot or memory across the system request.
    ///  * the Quick Look phase waits for the original single shared host slot,
    ///    stages a fresh copy from the same immutable CAS source, runs exactly
    ///    one bounded Quick Look request and deletes that copy on every exit.
    ///    At most one Quick Look copy exists; the legacy path below keeps its
    ///    original single 128 MiB copy bound.
    ///
    /// The extra bounded copy is the price of a real bound: previously the
    /// summary copy and its snapshot were retained while waiting for Quick
    /// Look, so the "two summary copies" limit was not enforced. The Quick Look
    /// policy (attempts, 45 s deadline, single cancel, no restart after
    /// timeout) is unchanged. The summary image is re-used as the settled
    /// fallback, so a failed or timed-out system request never re-reads or
    /// re-renders the package.
    private static func renderProgressiveResource(source: URL, fileExtension: String, size: CGSize,
                                                  request: (@MainActor (URL, CGSize, Duration) async -> NotesOfficeThumbnailGenerator.AttemptOutcome)? = nil,
                                                  emitFirstPaint: @escaping @MainActor (NotesDocumentCoverOutcome) -> Void) async -> NotesDocumentCoverOutcome {
        // Phase 1: bounded native OOXML summary in its own gated scope. Only
        // the rendered image crosses this boundary; the staged copy and the
        // parsed snapshot are gone before any Quick Look wait starts.
        let summary: UIImage?
        let summaryFailureStage: NotesDocumentCoverDiagnostics.FallbackStage
        switch await renderProgressiveSummary(source: source, fileExtension: fileExtension, size: size) {
        case .cancelled:
            return .init(image: nil, source: .none, diagnosis: "cancelled")
        case .summary(let image):
            summary = image
            summaryFailureStage = .quickLook
        case .unavailable(let stage):
            summary = nil
            summaryFailureStage = stage
        }
        if Task.isCancelled { return .init(image: nil, source: .none, diagnosis: "cancelled") }
        if let summary {
            emitFirstPaint(.init(image: summary, source: .officeContentSummary,
                                 diagnosis: "native content summary", diagnostics: nil))
        }

        // Phase 2: the unchanged bounded Quick Look request, now under the
        // shared host slot and on its own fresh copy of the immutable source.
        let slotID = UUID()
        guard await NotesOfficeThumbnailGate.shared.acquire(id: slotID) else {
            return .init(image: nil, source: .none, diagnosis: "cancelled")
        }
        defer { NotesOfficeThumbnailGate.shared.release() }
        if Task.isCancelled { return .init(image: nil, source: .none, diagnosis: "cancelled") }
        let staged: URL
        do {
            staged = try await NotesOfficeThumbnailStaging.stage(source: source, fileExtension: fileExtension)
        } catch is CancellationError {
            return .init(image: nil, source: .none, diagnosis: "cancelled")
        } catch {
            var diagnostics = NotesDocumentCoverDiagnostics()
            diagnostics.fallbackStage = .staging
            // The summary already crossed the phase boundary and (for the card
            // path) reached the first paint. A later staging failure — a full
            // disk, a permission change, a vanished source — must not clear a
            // real render of this resource and must never publish placeholder
            // pixels. Keep the same `UIImage` and label the fallback stage.
            guard let summary else {
                return .init(image: nil, source: .unsupported,
                             diagnosis: String(localized: "notes.cover.office.quickLookUnavailable",
                                               defaultValue: "Quick Look is unavailable"),
                             diagnostics: diagnostics)
            }
            return .init(image: summary, source: .officeContentSummary,
                         diagnosis: "native content summary",
                         diagnostics: diagnostics)
        }
        defer { NotesOfficeThumbnailStaging.remove(staged) }
        if Task.isCancelled { return .init(image: nil, source: .none, diagnosis: "cancelled") }

        var diagnostics = NotesDocumentCoverDiagnostics()
        let outcome = await NotesOfficeThumbnailGenerator.thumbnail(
            url: staged, size: size,
            fileExtension: fileExtension,
            request: request)
        diagnostics.quickLookAttempts = outcome.attempts
        diagnostics.quickLookTimedOut = outcome.timedOut
        diagnostics.quickLookErrorDomain = NotesDocumentCoverDiagnostics.boundedDomain(outcome.errorDomain)
        diagnostics.quickLookErrorCode = outcome.errorCode
        diagnostics.quickLookWasIconFallback = outcome.wasIconFallback
        if Task.isCancelled { return .init(image: nil, source: .none, diagnosis: "cancelled") }
        if let image = outcome.image {
            NotesOfficeThumbnailGenerator.logSuccess(fileExtension: fileExtension, attempt: outcome.attempts,
                                                     elapsed: outcome.elapsed)
            return .init(image: image, source: .quickLookThumbnail, diagnosis: "quick look",
                         diagnostics: diagnostics)
        }
        NotesOfficeThumbnailGenerator.logUnavailable(fileExtension: fileExtension, outcome: outcome)
        let quickLookDiagnosis = outcome.wasIconFallback
            ? String(localized: "notes.cover.office.iconOnly", defaultValue: "Quick Look returned only a generic icon")
            : String(localized: "notes.cover.office.noQuickLook", defaultValue: "Quick Look did not produce a content thumbnail")
        // The settled fallback is the already-rendered summary image; nothing
        // is read or parsed a second time.
        guard let summary else {
            diagnostics.fallbackStage = summaryFailureStage
            return .init(image: nil, source: .unsupported, diagnosis: quickLookDiagnosis,
                         diagnostics: diagnostics)
        }
        return .init(image: summary, source: .officeContentSummary, diagnosis: "native content summary",
                     diagnostics: diagnostics)
    }

    /// The outcome of the isolated summary phase. `.summary` carries only the
    /// rendered image; the snapshot and the staged copy never leave the phase.
    private enum ProgressiveSummaryResult {
        case summary(UIImage)
        case unavailable(NotesDocumentCoverDiagnostics.FallbackStage)
        case cancelled
    }

    /// Phase 1 of the progressive path and the only place a summary copy
    /// exists. The two-slot summary gate bounds concurrent summary copies (and
    /// parsed snapshots) to two; the function-scope `defer`s delete the staged
    /// copy and release the slot on every exit, including cancellation. Only
    /// the rendered `UIImage` crosses the phase boundary, so the
    /// `OfficeDocumentSnapshot` is never retained while waiting for Quick Look.
    private static func renderProgressiveSummary(source: URL, fileExtension: String, size: CGSize) async -> ProgressiveSummaryResult {
        guard let kind = summaryDocumentKind(for: fileExtension) else {
            return .unavailable(.unsupportedType)
        }
        let slotID = UUID()
        guard await NotesOfficeThumbnailGate.summary.acquire(id: slotID) else {
            return .cancelled
        }
        defer { NotesOfficeThumbnailGate.summary.release() }
        if Task.isCancelled { return .cancelled }

        let staged: URL
        do {
            staged = try await NotesOfficeThumbnailStaging.stage(source: source, fileExtension: fileExtension)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .unavailable(.staging)
        }
        defer { NotesOfficeThumbnailStaging.remove(staged) }
        if Task.isCancelled { return .cancelled }

        let snapshot: OfficeDocumentSnapshot? = await Task.detached(priority: .utility) {
            try? OfficeDocumentService.inspect(url: staged)
        }.value
        if Task.isCancelled { return .cancelled }
        guard let snapshot, !snapshot.fields.isEmpty else { return .unavailable(.inspect) }
        let summary: UIImage? = await Task.detached(priority: .utility) {
            contentSummary(snapshot: snapshot, kind: kind, size: size)
        }.value
        if Task.isCancelled { return .cancelled }
        guard let summary else { return .unavailable(.render) }
        return .summary(summary)
    }

    /// Original Quick Look-first path for legacy/binary/OpenDocument formats
    /// and for modern OOXML above the native summary bound. The shared host
    /// slot is acquired BEFORE staging: a staged copy can be up to 128 MiB, so
    /// copying must be bounded by the same gate as generation. It also bounds
    /// the native OOXML summary digest below.
    private static func renderQuickLookFirstResource(source: URL, fileExtension: String, size: CGSize,
                                                     sourceBytes: Int,
                                                     request: (@MainActor (URL, CGSize, Duration) async -> NotesOfficeThumbnailGenerator.AttemptOutcome)? = nil) async -> NotesDocumentCoverOutcome {
        let slotID = UUID()
        guard await NotesOfficeThumbnailGate.shared.acquire(id: slotID) else {
            return .init(image: nil, source: .none, diagnosis: "cancelled")
        }
        defer { NotesOfficeThumbnailGate.shared.release() }
        if Task.isCancelled { return .init(image: nil, source: .none, diagnosis: "cancelled") }

        // Quick Look keys off the file extension while a Notes resource is the
        // extensionless CAS path. Stage exactly one validated, bounded copy and
        // keep it for Quick Look *and* the native summary fallback: both must
        // read the same bytes, and every return (including cancellation)
        // removes the staging directory through the function-scope defer.
        let staged: URL
        do {
            staged = try await NotesOfficeThumbnailStaging.stage(source: source, fileExtension: fileExtension)
        } catch is CancellationError {
            return .init(image: nil, source: .none, diagnosis: "cancelled")
        } catch {
            var diagnostics = NotesDocumentCoverDiagnostics()
            diagnostics.fallbackStage = .staging
            return .init(image: nil, source: .unsupported,
                         diagnosis: String(localized: "notes.cover.office.quickLookUnavailable",
                                           defaultValue: "Quick Look is unavailable"),
                         diagnostics: diagnostics)
        }
        defer { NotesOfficeThumbnailStaging.remove(staged) }

        var diagnostics = NotesDocumentCoverDiagnostics()
        let outcome = await NotesOfficeThumbnailGenerator.thumbnail(
            url: staged, size: size,
            fileExtension: fileExtension,
            request: request)
        diagnostics.quickLookAttempts = outcome.attempts
        diagnostics.quickLookTimedOut = outcome.timedOut
        diagnostics.quickLookErrorDomain = NotesDocumentCoverDiagnostics.boundedDomain(outcome.errorDomain)
        diagnostics.quickLookErrorCode = outcome.errorCode
        diagnostics.quickLookWasIconFallback = outcome.wasIconFallback
        if Task.isCancelled { return .init(image: nil, source: .none, diagnosis: "cancelled") }
        if let image = outcome.image {
            NotesOfficeThumbnailGenerator.logSuccess(fileExtension: fileExtension, attempt: outcome.attempts,
                                                     elapsed: outcome.elapsed)
            return .init(image: image, source: .quickLookThumbnail, diagnosis: "quick look",
                         diagnostics: diagnostics)
        }
        NotesOfficeThumbnailGenerator.logUnavailable(fileExtension: fileExtension, outcome: outcome)
        let quickLookDiagnosis = outcome.wasIconFallback
            ? String(localized: "notes.cover.office.iconOnly", defaultValue: "Quick Look returned only a generic icon")
            : String(localized: "notes.cover.office.noQuickLook", defaultValue: "Quick Look did not produce a content thumbnail")

        // The native OOXML inspector understands modern docx/xlsx/pptx only;
        // legacy/binary and OpenDocument formats stay explicitly unsupported.
        guard let kind = OfficeDocumentKind(url: staged) else {
            diagnostics.fallbackStage = .unsupportedType
            return .init(image: nil, source: .unsupported, diagnosis: quickLookDiagnosis,
                         diagnostics: diagnostics)
        }
        // The summary fallback parses the package off the main actor. It is
        // capped below the Quick Look bound so a card can never inflate a large
        // ZIP in the UI process.
        guard sourceBytes <= maximumSummarySourceBytes else {
            diagnostics.fallbackStage = .sizeLimit
            return .init(image: nil, source: .unsupported, diagnosis: quickLookDiagnosis,
                         diagnostics: diagnostics)
        }
        let snapshot: OfficeDocumentSnapshot? = await Task.detached(priority: .utility) {
            try? OfficeDocumentService.inspect(url: staged)
        }.value
        if Task.isCancelled { return .init(image: nil, source: .none, diagnosis: "cancelled") }
        guard let snapshot, !snapshot.fields.isEmpty else {
            diagnostics.fallbackStage = .inspect
            return .init(image: nil, source: .unsupported, diagnosis: quickLookDiagnosis,
                         diagnostics: diagnostics)
        }
        // Drawing is a pure, bounded render (<= 240 fields); keep it off the
        // main actor as well so a card never blocks scrolling.
        let summary: UIImage? = await Task.detached(priority: .utility) {
            contentSummary(snapshot: snapshot, kind: kind, size: size)
        }.value
        if Task.isCancelled { return .init(image: nil, source: .none, diagnosis: "cancelled") }
        guard let summary else {
            diagnostics.fallbackStage = .render
            return .init(image: nil, source: .unsupported, diagnosis: quickLookDiagnosis,
                         diagnostics: diagnostics)
        }
        return .init(image: summary, source: .officeContentSummary, diagnosis: "native content summary",
                     diagnostics: diagnostics)
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
