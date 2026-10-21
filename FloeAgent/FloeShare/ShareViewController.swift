// SPDX-License-Identifier: MPL-2.0
//
// FloeShare — Share extension entry point (S5 P1).
//
// The extension's ONLY job is to stage a bounded, validated envelope in the
// shared App Group and tell the user to open Floe. It never opens the main app
// (`NSExtensionContext.open` is unsupported for share extensions), never
// sends a task and never claims success for a failed write.
//
// Provider handling:
// * text / URL are loaded into memory only up to the 1 MiB envelope limit.
// * image / file providers are copied through `loadFileRepresentation` inside
//   the provider URL lifetime, with a bounded streaming copy and file
//   coordination. Original bytes and provider type identifiers are preserved.
// * the UIImage-only fallback is limited to a 2048 px PNG (never a silent
//   lossy JPEG); anything larger/corrupt is rejected with a visible error.
// * at most five items are accepted; the whole share is rejected when more
//   are present rather than silently dropping the rest.

import UIKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import FloeCore

final class ShareViewController: UIViewController {
    private var confirmationState = ShareConfirmationState(phase: .saving)
    private var hostingController: UIHostingController<ShareConfirmationView>?
    private var stagingSession: ShareInbox.StagingSession?
    private var processingTask: Task<Void, Never>?
    private var temporaryDirectory: URL?
    private var didFinish = false
    private var hasRequestedCompletion = false
    private var failureMessage: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        FloeL10n.bootstrap()
        view.backgroundColor = .systemBackground
        installHostingControllerIfNeeded()
        updateConfirmation(.init(phase: .saving))
        startProcessing()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !didFinish else { return }
        // The user dismissed the share sheet before tapping Done. Remove only
        // this extension's uncommitted staging bytes and temporary copies.
        processingTask?.cancel()
        stagingSession?.cancel()
        stagingSession = nil
        cleanupTemporaryDirectory()
    }

    // MARK: - Processing

    private func startProcessing() {
        processingTask = Task { [weak self] in
            await self?.processSharedContent()
        }
    }

    private func processSharedContent() async {
        do {
            guard let extensionContext,
                  let inputItems = extensionContext.inputItems as? [NSExtensionItem] else {
                throw ShareInboxError.emptyEnvelope
            }
            let inbox = try ShareInbox.applicationGroup()
            let session = try inbox.beginStaging(producer: "FloeShare")
            stagingSession = session

            let tempRoot = try makeTemporaryDirectory()
            let inputs = try await ShareItemProviderLoader.loadInputs(
                from: inputItems,
                temporaryRoot: tempRoot
            )
            try Task.checkCancellation()
            guard !inputs.isEmpty else {
                throw ShareInboxError.emptyEnvelope
            }
            for input in inputs {
                try Task.checkCancellation()
                switch input {
                case .text(let text):
                    try session.appendText(text, kind: .text)
                case .url(let absoluteString):
                    try session.appendText(absoluteString, kind: .url)
                case .file(let url, let displayName, let typeIdentifier, let kind):
                    try session.adoptTemporaryFile(
                        at: url,
                        displayName: displayName,
                        typeIdentifier: typeIdentifier,
                        kind: kind
                    )
                case .data(let data, let displayName, let typeIdentifier, let kind):
                    try session.appendData(
                        data,
                        displayName: displayName,
                        typeIdentifier: typeIdentifier,
                        kind: kind
                    )
                }
            }
            let envelope = try session.commit()
            stagingSession = nil
            cleanupTemporaryDirectory()
            didFinish = true
            failureMessage = nil
            updateConfirmation(.init(phase: .saved(itemCount: envelope.items.count)))
        } catch is CancellationError {
            stagingSession?.cancel()
            stagingSession = nil
            cleanupTemporaryDirectory()
        } catch {
            stagingSession?.cancel()
            stagingSession = nil
            cleanupTemporaryDirectory()
            let message: String
            if let inboxError = error as? ShareInboxError {
                message = inboxError.localizedDescription
            } else {
                message = FloeL10n.l("share.extension.failed_detail")
            }
            failureMessage = message
            updateConfirmation(.init(phase: .failed(message: message)))
        }
    }

    private func retry() {
        guard !hasRequestedCompletion else { return }
        processingTask?.cancel()
        stagingSession?.cancel()
        stagingSession = nil
        cleanupTemporaryDirectory()
        failureMessage = nil
        updateConfirmation(.init(phase: .saving))
        startProcessing()
    }

    // MARK: - Completion

    private func finishWithSuccess() {
        guard !hasRequestedCompletion else { return }
        hasRequestedCompletion = true
        didFinish = true
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private func finishWithFailure() {
        guard !hasRequestedCompletion else { return }
        hasRequestedCompletion = true
        didFinish = true
        let message = failureMessage ?? FloeL10n.l("share.extension.failed_detail")
        let error = NSError(
            domain: "org.floeagent.share",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        // Not a success completion: the host learns the share was not saved.
        extensionContext?.cancelRequest(withError: error)
    }

    // MARK: - Hosting

    private func installHostingControllerIfNeeded() {
        guard hostingController == nil else { return }
        let controller = UIHostingController(rootView: makeConfirmationView())
        controller.view.backgroundColor = .clear
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.didMove(toParent: self)
        hostingController = controller
        preferredContentSize = CGSize(width: 420, height: 260)
    }

    private func updateConfirmation(_ state: ShareConfirmationState) {
        confirmationState = state
        installHostingControllerIfNeeded()
        hostingController?.rootView = makeConfirmationView()
    }

    private func makeConfirmationView() -> ShareConfirmationView {
        ShareConfirmationView(
            state: confirmationState,
            onDone: { [weak self] in self?.finishWithSuccess() },
            onClose: { [weak self] in self?.finishWithFailure() },
            onRetry: { [weak self] in self?.retry() }
        )
    }

    // MARK: - Temporary files

    private func makeTemporaryDirectory() throws -> URL {
        if let temporaryDirectory {
            return temporaryDirectory
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeShare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectory = url
        return url
    }

    private func cleanupTemporaryDirectory() {
        guard let temporaryDirectory else { return }
        try? FileManager.default.removeItem(at: temporaryDirectory)
        self.temporaryDirectory = nil
    }
}

// MARK: - Provider decoding

private enum ShareItemInput: Sendable {
    case text(String)
    case url(String)
    case file(URL, displayName: String?, typeIdentifier: String, kind: ShareInboxItemKind)
    case data(Data, displayName: String?, typeIdentifier: String, kind: ShareInboxItemKind)
}

private enum ShareItemProviderLoader {
    static let maxItems = ShareInboxLimits.standard.maxItems
    static let maxItemBytes = ShareInboxLimits.standard.maxItemBytes
    static let maxTextBytes = ShareInboxLimits.standard.maxTextBytes

    @MainActor
    static func loadInputs(
        from extensionItems: [NSExtensionItem],
        temporaryRoot: URL
    ) async throws -> [ShareItemInput] {
        var inputs: [ShareItemInput] = []
        for extensionItem in extensionItems {
            guard let providers = extensionItem.attachments, !providers.isEmpty else {
                if let text = extensionItem.attributedContentText?.string
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    try append(.text(text), to: &inputs)
                }
                continue
            }

            // Safari and similar apps register BOTH a URL and a plain-text
            // representation for one shared page. The URL is the payload; the
            // text copy is skipped to avoid storing the same share twice.
            let hasURLProvider = providers.contains {
                $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            }

            for provider in providers {
                if hasURLProvider,
                   provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    continue
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    let value = try await loadString(provider, type: .url)
                    try append(.url(value), to: &inputs)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    try append(
                        try await loadImage(provider, temporaryRoot: temporaryRoot),
                        to: &inputs
                    )
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    let value = try await loadString(provider, type: .plainText)
                    try append(.text(value), to: &inputs)
                } else if let typeIdentifier = genericFileTypeIdentifier(for: provider) {
                    try append(
                        try await loadFile(
                            provider,
                            typeIdentifier: typeIdentifier,
                            temporaryRoot: temporaryRoot
                        ),
                        to: &inputs
                    )
                } else {
                    throw ShareInboxError.unsupportedItem(reason: "provider")
                }
            }
        }
        return inputs
    }

    private static func append(_ input: ShareItemInput, to inputs: inout [ShareItemInput]) throws {
        guard inputs.count < maxItems else {
            throw ShareInboxError.itemLimitExceeded(limit: maxItems)
        }
        inputs.append(input)
    }

    // MARK: Text / URL

    @MainActor
    private static func loadString(
        _ provider: NSItemProvider,
        type: UTType
    ) async throws -> String {
        let typeIdentifier = preferredTypeIdentifier(provider, conformingTo: type)
            ?? type.identifier
        let loaded = try await loadItem(provider, typeIdentifier: typeIdentifier)
        let value: String
        switch loaded {
        case .text(let text):
            value = text
        case .url(let url):
            value = url.absoluteString
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                throw ShareInboxError.unsupportedItem(reason: "textEncoding")
            }
            value = text
        case .convertedPNG:
            throw ShareInboxError.unsupportedItem(reason: "textImage")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ShareInboxError.unsupportedItem(reason: "emptyText")
        }
        guard value.utf8.count <= maxTextBytes else {
            throw ShareInboxError.textTooLarge(
                byteCount: value.utf8.count,
                limit: maxTextBytes
            )
        }
        return value
    }

    // MARK: Image

    @MainActor
    private static func loadImage(
        _ provider: NSItemProvider,
        temporaryRoot: URL
    ) async throws -> ShareItemInput {
        let displayName = provider.suggestedName
        let registeredType = preferredTypeIdentifier(provider, conformingTo: .image)

        if let registeredType,
           let stagedURL = try await fileRepresentationIfPossible(
            provider,
            typeIdentifier: registeredType,
            temporaryRoot: temporaryRoot,
            baseName: "image",
            fallbackExtension: UTType(registeredType)?.preferredFilenameExtension
           ) {
            return .file(
                stagedURL,
                displayName: displayName ?? stagedURL.lastPathComponent,
                typeIdentifier: registeredType,
                kind: .image
            )
        }

        let typeIdentifier = registeredType ?? UTType.image.identifier
        let loaded = try await loadItem(provider, typeIdentifier: typeIdentifier)
        switch loaded {
        case .url(let url):
            let destination = temporaryPath(
                temporaryRoot: temporaryRoot,
                baseName: "image",
                sourceExtension: url.pathExtension,
                fallbackExtension: UTType(typeIdentifier)?.preferredFilenameExtension
            )
            try ShareInbox.copyFileBounded(
                from: url,
                to: destination,
                maxBytes: maxItemBytes
            )
            return .file(
                destination,
                displayName: displayName ?? url.lastPathComponent,
                typeIdentifier: typeIdentifier,
                kind: .image
            )
        case .data(let data):
            guard data.count <= maxItemBytes else {
                throw ShareInboxError.itemTooLarge(byteCount: data.count, limit: maxItemBytes)
            }
            if isConcreteImageType(typeIdentifier) {
                // PRESERVE the provider's original image bytes and type.
                return .data(
                    data,
                    displayName: displayName ?? defaultImageName(for: typeIdentifier),
                    typeIdentifier: typeIdentifier,
                    kind: .image
                )
            }
            let png = try ImageEncoding.boundedPNG(from: data, maxBytes: maxItemBytes)
            return .data(
                png,
                displayName: (displayName ?? "Image") + ".png",
                typeIdentifier: UTType.png.identifier,
                kind: .image
            )
        case .convertedPNG(let png):
            return .data(
                png,
                displayName: (displayName ?? "Image") + ".png",
                typeIdentifier: UTType.png.identifier,
                kind: .image
            )
        case .text:
            throw ShareInboxError.unsupportedItem(reason: "imageText")
        }
    }

    private static func isConcreteImageType(_ identifier: String) -> Bool {
        guard identifier != UTType.image.identifier,
              let type = UTType(identifier) else { return false }
        return type.conforms(to: .image)
    }

    private static func defaultImageName(for identifier: String) -> String {
        let ext = UTType(identifier)?.preferredFilenameExtension ?? "img"
        return "Image.\(ext)"
    }

    // MARK: File

    @MainActor
    private static func loadFile(
        _ provider: NSItemProvider,
        typeIdentifier: String,
        temporaryRoot: URL
    ) async throws -> ShareItemInput {
        let displayName = provider.suggestedName
        if let stagedURL = try await fileRepresentationIfPossible(
            provider,
            typeIdentifier: typeIdentifier,
            temporaryRoot: temporaryRoot,
            baseName: "file",
            fallbackExtension: UTType(typeIdentifier)?.preferredFilenameExtension
        ) {
            return .file(
                stagedURL,
                displayName: displayName ?? stagedURL.lastPathComponent,
                typeIdentifier: typeIdentifier,
                kind: .file
            )
        }

        let loaded = try await loadItem(provider, typeIdentifier: typeIdentifier)
        switch loaded {
        case .url(let url):
            let destination = temporaryPath(
                temporaryRoot: temporaryRoot,
                baseName: "file",
                sourceExtension: url.pathExtension,
                fallbackExtension: UTType(typeIdentifier)?.preferredFilenameExtension
            )
            try ShareInbox.copyFileBounded(from: url, to: destination, maxBytes: maxItemBytes)
            return .file(
                destination,
                displayName: displayName ?? url.lastPathComponent,
                typeIdentifier: typeIdentifier,
                kind: .file
            )
        case .data(let data):
            guard data.count <= maxItemBytes else {
                throw ShareInboxError.itemTooLarge(byteCount: data.count, limit: maxItemBytes)
            }
            return .data(
                data,
                displayName: displayName,
                typeIdentifier: typeIdentifier,
                kind: .file
            )
        case .convertedPNG(let png):
            guard png.count <= maxItemBytes else {
                throw ShareInboxError.itemTooLarge(byteCount: png.count, limit: maxItemBytes)
            }
            return .data(
                png,
                displayName: (displayName ?? "File") + ".png",
                typeIdentifier: UTType.png.identifier,
                kind: .file
            )
        case .text:
            throw ShareInboxError.unsupportedItem(reason: "fileText")
        }
    }

    // MARK: Item loading

    private enum LoadedItem: Sendable {
        case text(String)
        case url(URL)
        case data(Data)
        case convertedPNG(Data)
    }

    @MainActor
    private static func loadItem(
        _ provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> LoadedItem {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LoadedItem, Error>) in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let string = item as? String {
                    continuation.resume(returning: .text(string))
                    return
                }
                if let string = item as? NSString {
                    continuation.resume(returning: .text(string as String))
                    return
                }
                if let attributed = item as? NSAttributedString {
                    continuation.resume(returning: .text(attributed.string))
                    return
                }
                if let url = item as? URL {
                    continuation.resume(returning: .url(url))
                    return
                }
                if let url = item as? NSURL {
                    continuation.resume(returning: .url(url as URL))
                    return
                }
                if let data = item as? Data {
                    continuation.resume(returning: .data(data))
                    return
                }
                if let image = item as? UIImage {
                    do {
                        let png = try ImageEncoding.boundedPNG(
                            from: image,
                            maxBytes: maxItemBytes
                        )
                        continuation.resume(returning: .convertedPNG(png))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                continuation.resume(
                    throwing: ShareInboxError.unsupportedItem(reason: "loadedItem")
                )
            }
        }
    }

    /// A provider that only supports NSItemProvider.loadItem may report a
    /// representation error here; fall back to loadItem for that case, but
    /// never hide a size or disk failure.
    @MainActor
    private static func fileRepresentationIfPossible(
        _ provider: NSItemProvider,
        typeIdentifier: String,
        temporaryRoot: URL,
        baseName: String,
        fallbackExtension: String?
    ) async throws -> URL? {
        do {
            return try await copyFileRepresentation(
                provider,
                typeIdentifier: typeIdentifier,
                temporaryRoot: temporaryRoot,
                baseName: baseName,
                fallbackExtension: fallbackExtension
            )
        } catch let error as ShareInboxError {
            switch error {
            case .itemTooLarge, .insufficientSpace, .textTooLarge:
                throw error
            default:
                return nil
            }
        } catch {
            return nil
        }
    }

    @MainActor
    private static func copyFileRepresentation(
        _ provider: NSItemProvider,
        typeIdentifier: String,
        temporaryRoot: URL,
        baseName: String,
        fallbackExtension: String?
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url else {
                    continuation.resume(
                        throwing: ShareInboxError.unsupportedItem(reason: "fileRepresentation")
                    )
                    return
                }
                let destination = temporaryPath(
                    temporaryRoot: temporaryRoot,
                    baseName: baseName,
                    sourceExtension: url.pathExtension,
                    fallbackExtension: fallbackExtension
                )
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }

                let box = CoordinatedCopyBox()
                var coordinationError: NSError?
                NSFileCoordinator().coordinate(
                    readingItemAt: url,
                    options: [],
                    error: &coordinationError
                ) { readableURL in
                    do {
                        try ShareInbox.copyFileBounded(
                            from: readableURL,
                            to: destination,
                            maxBytes: maxItemBytes
                        )
                    } catch {
                        box.error = error
                    }
                }
                if let error = box.error {
                    continuation.resume(throwing: error)
                } else if let coordinationError {
                    continuation.resume(throwing: coordinationError)
                } else {
                    continuation.resume(returning: destination)
                }
            }
        }
    }

    // MARK: Helpers

    private static func preferredTypeIdentifier(
        _ provider: NSItemProvider,
        conformingTo type: UTType
    ) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            guard let candidate = UTType(identifier) else { return false }
            return candidate.conforms(to: type)
        }
    }

    private static func genericFileTypeIdentifier(for provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            guard type.conforms(to: .data) || type.conforms(to: .content) else { return false }
            return !type.conforms(to: .text)
                && !type.conforms(to: .url)
                && !type.conforms(to: .image)
        }
    }

    private static func temporaryPath(
        temporaryRoot: URL,
        baseName: String,
        sourceExtension: String?,
        fallbackExtension: String?
    ) -> URL {
        let rawExtension = (sourceExtension?.isEmpty == false ? sourceExtension : fallbackExtension) ?? "dat"
        let cleaned = rawExtension.lowercased().unicodeScalars
            .filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        let suffix = cleaned.isEmpty ? "dat" : String(cleaned.prefix(16))
        return temporaryRoot.appendingPathComponent(
            "\(baseName)-\(UUID().uuidString).\(suffix)"
        )
    }
}

private final class CoordinatedCopyBox: @unchecked Sendable {
    var error: Error?
}

// MARK: - Bounded image fallback

private enum ImageEncoding {
    static let maxPixelDimension: CGFloat = 2_048

    static func boundedPNG(from image: UIImage, maxBytes: Int) throws -> Data {
        let width = image.size.width
        let height = image.size.height
        guard width > 0, height > 0 else {
            throw ShareInboxError.unsupportedItem(reason: "imageSize")
        }
        let scale = min(1, maxPixelDimension / max(width, height))
        let target = CGSize(
            width: max(1, (width * scale).rounded()),
            height: max(1, (height * scale).rounded())
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = rendered.pngData() else {
            throw ShareInboxError.unsupportedItem(reason: "imageEncode")
        }
        guard data.count <= maxBytes else {
            throw ShareInboxError.itemTooLarge(byteCount: data.count, limit: maxBytes)
        }
        return data
    }

    /// Bounded fallback for providers that expose image DATA but no file
    /// representation. Downscaling happens in ImageIO; the full image is never
    /// decoded into a second full-size buffer.
    static func boundedPNG(from data: Data, maxBytes: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ShareInboxError.unsupportedItem(reason: "imageDecode")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelDimension),
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw ShareInboxError.unsupportedItem(reason: "imageThumbnail")
        }
        guard let png = UIImage(cgImage: cgImage).pngData() else {
            throw ShareInboxError.unsupportedItem(reason: "imageEncode")
        }
        guard png.count <= maxBytes else {
            throw ShareInboxError.itemTooLarge(byteCount: png.count, limit: maxBytes)
        }
        return png
    }
}
