// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit
import Foundation
import QuickLookThumbnailing
import FloeNotes
import PencilKit

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
    private static let thumbnailTimeout: Duration = .seconds(15)
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
        // carrying the validated Office filename extension is staged per request.
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
            let slotID = UUID()
            guard await NotesOfficeThumbnailGate.shared.acquire(id: slotID) else { return }
            defer { NotesOfficeThumbnailGate.shared.release() }
            try Task.checkCancellation()
            let staged = try await NotesOfficeThumbnailStaging.stage(source: url, fileExtension: fileExtension)
            defer { NotesOfficeThumbnailStaging.remove(staged) }
            let generated = await Self.generateThumbnail(url: staged, size: Self.thumbnailSize, timeout: Self.thumbnailTimeout)
            try Task.checkCancellation()
            apply(generated, key: key)
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

    /// Bounded and cancellable Quick Look request: one hard timeout, no polling,
    /// explicit cancellation of the generator request, and a guarded single
    /// resume shared by the generator callback, the timeout and cancellation.
    private static func generateThumbnail(url: URL, size: CGSize, timeout: Duration) async -> UIImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 1, representationTypes: .thumbnail)
        let state = NotesThumbnailRequestState(request: request)
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            state.cancel()
        }
        defer { timeoutTask.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                guard state.attach(continuation) else { return }
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                    let image = representation?.uiImage
                    Task { @MainActor in state.finish(image) }
                }
            }
        } onCancel: {
            Task { @MainActor in state.cancel() }
        }
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
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var finished = false

    init(request: QLThumbnailGenerator.Request) { self.request = request }

    func attach(_ continuation: CheckedContinuation<UIImage?, Never>) -> Bool {
        guard !finished else { continuation.resume(returning: nil); return false }
        self.continuation = continuation
        return true
    }

    func finish(_ image: UIImage?) {
        guard !finished else { return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: image)
    }

    func cancel() {
        guard !finished else { return }
        QLThumbnailGenerator.shared.cancel(request)
        finish(nil)
    }
}
#endif
