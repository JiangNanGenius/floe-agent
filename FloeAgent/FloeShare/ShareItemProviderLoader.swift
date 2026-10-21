// SPDX-License-Identifier: MPL-2.0
//
// FloeShare — inbound Share provider decoding (S5 P1).
//
// Extracted from ShareViewController so the file-vs-URL selection boundary
// is compilable into the FloeAppTests bundle (project.yml lists this file
// the same way it lists the FloeFileProvider sources) and can be driven with
// real NSItemProvider instances.
//
// Provider handling:
// * Conforming to public.url does NOT mean "web page": a file share's URL
//   representation points at the source app's transient coordinated
//   location, which expires around the provider callback. When a provider
//   advertises a real file representation it wins: the coordinated bytes
//   are copied INSIDE the provider callback into this process's own
//   temporary directory (later adopted into staging), preserving the
//   original name, the concrete type and the content digest.
// * A public.url value delivered as URL/NSURL or as a String/text/UTF-8
//   representation that resolves to a file: location gets the same
//   treatment from its FIRST applicable loadItem callback — never a
//   second provider request as a lifetime workaround. If the bytes cannot
//   be retained as a regular, readable file the item is rejected
//   honestly; the transient location is never committed as envelope text.
// * Genuine http/https web page URLs and other non-file URL/text inputs
//   keep the exact previous behavior. Network locations are never
//   dereferenced as files.
// * text / URL are loaded into memory only up to the text envelope limit.
// * image / file providers are copied through `loadFileRepresentation`
//   inside the provider URL lifetime, with a bounded streaming copy and
//   file coordination. Original bytes and provider type identifiers are
//   preserved.
// * the UIImage-only fallback is limited to 2048 px PNG (never a silent
//   lossy JPEG); anything larger/corrupt is rejected with a visible error.
// * at most five items are accepted; the whole share is rejected when more
//   are present rather than silently dropping the rest.

import UIKit
import ImageIO
import UniformTypeIdentifiers
import FloeCore

enum ShareItemInput: Sendable {
    case text(String)
    case url(String)
    case file(URL, displayName: String?, typeIdentifier: String, kind: ShareInboxItemKind)
    case data(Data, displayName: String?, typeIdentifier: String, kind: ShareInboxItemKind)
}

enum ShareItemProviderLoader {
    @MainActor
    static func loadInputs(
        from extensionItems: [NSExtensionItem],
        temporaryRoot: URL,
        limits: ShareInboxLimits = .standard
    ) async throws -> [ShareItemInput] {
        var inputs: [ShareItemInput] = []
        for extensionItem in extensionItems {
            guard let providers = extensionItem.attachments, !providers.isEmpty else {
                if let text = extensionItem.attributedContentText?.string
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    try append(.text(text), to: &inputs, limits: limits)
                }
                continue
            }

            // Safari and similar apps sometimes register the page URL and a
            // plain-text companion as SEPARATE attachments. Only that
            // separate plain-text companion — no URL and no file
            // representation of its own — is the deduplication target. A
            // provider that exposes public.url and public.plain-text
            // together IS the URL payload and must never be skipped.
            let hasURLProvider = providers.contains {
                $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            }

            for provider in providers {
                try Task.checkCancellation()
                let preferredFileTypeIdentifier =
                    ShareProviderIntakePolicy.preferredFileRepresentationTypeIdentifier(
                        registeredTypeIdentifiers: provider.registeredTypeIdentifiers
                    )
                if hasURLProvider,
                   preferredFileTypeIdentifier == nil,
                   !provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    continue
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    try append(
                        await loadURLProvider(
                            provider,
                            preferredFileTypeIdentifier: preferredFileTypeIdentifier,
                            temporaryRoot: temporaryRoot,
                            limits: limits
                        ),
                        to: &inputs,
                        limits: limits
                    )
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    try append(
                        try await loadImage(
                            provider,
                            temporaryRoot: temporaryRoot,
                            limits: limits
                        ),
                        to: &inputs,
                        limits: limits
                    )
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    let value = try await loadString(provider, type: .plainText, limits: limits)
                    try append(.text(value), to: &inputs, limits: limits)
                } else if let typeIdentifier = genericFileTypeIdentifier(for: provider) {
                    try append(
                        try await loadFile(
                            provider,
                            typeIdentifier: typeIdentifier,
                            temporaryRoot: temporaryRoot,
                            limits: limits
                        ),
                        to: &inputs,
                        limits: limits
                    )
                } else {
                    throw ShareInboxError.unsupportedItem(reason: "provider")
                }
            }
        }
        return inputs
    }

    private static func append(
        _ input: ShareItemInput,
        to inputs: inout [ShareItemInput],
        limits: ShareInboxLimits
    ) throws {
        guard inputs.count < limits.maxItems else {
            throw ShareInboxError.itemLimitExceeded(limit: limits.maxItems)
        }
        inputs.append(input)
    }

    // MARK: public.url providers

    /// The URL-provider intake boundary, in order:
    /// 1. A concrete file representation advertised next to the URL wins:
    ///    it is loaded through `loadFile` (image types keep the image
    ///    loader), and the generic public.url representation is never
    ///    requested afterwards.
    /// 2. Otherwise the URL representation is loaded exactly ONCE, inside
    ///    one callback: file: locations (delivered as URL/NSURL or as
    ///    String/text/UTF-8) retain their bytes before that callback
    ///    returns; every other value keeps the previous text-URL behavior.
    @MainActor
    private static func loadURLProvider(
        _ provider: NSItemProvider,
        preferredFileTypeIdentifier: String?,
        temporaryRoot: URL,
        limits: ShareInboxLimits
    ) async throws -> ShareItemInput {
        if let preferredFileTypeIdentifier {
            if UTType(preferredFileTypeIdentifier)?.conforms(to: .image) == true {
                return try await loadImage(provider, temporaryRoot: temporaryRoot, limits: limits)
            }
            return try await loadFile(
                provider,
                typeIdentifier: preferredFileTypeIdentifier,
                temporaryRoot: temporaryRoot,
                limits: limits
            )
        }

        let urlTypeIdentifier = preferredTypeIdentifier(provider, conformingTo: .url)
            ?? UTType.url.identifier
        switch try await loadURLRepresentation(
            provider,
            typeIdentifier: urlTypeIdentifier,
            temporaryRoot: temporaryRoot,
            limits: limits
        ) {
        case .retainedFile(let staged):
            return fileInput(
                staged: staged,
                provider: provider,
                requestedTypeIdentifier: urlTypeIdentifier
            )
        case .textURL(let value):
            return .url(value)
        }
    }

    private static func fileInput(
        staged: StagedRepresentation,
        provider: NSItemProvider,
        requestedTypeIdentifier: String
    ) -> ShareItemInput {
        let displayName = provider.suggestedName ?? staged.originalName ?? staged.url.lastPathComponent
        let typeIdentifier = ShareProviderIntakePolicy.refinedTypeIdentifier(
            requestedTypeIdentifier: requestedTypeIdentifier,
            originalFileName: displayName
        )
        return .file(
            staged.url,
            displayName: displayName,
            typeIdentifier: typeIdentifier,
            kind: .file
        )
    }

    // MARK: Text / URL

    @MainActor
    private static func loadString(
        _ provider: NSItemProvider,
        type: UTType,
        limits: ShareInboxLimits
    ) async throws -> String {
        let typeIdentifier = preferredTypeIdentifier(provider, conformingTo: type)
            ?? type.identifier
        let loaded = try await loadItem(
            provider,
            typeIdentifier: typeIdentifier,
            retainFileURLsInto: nil,
            limits: limits
        )
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
        case .retainedFile:
            throw ShareInboxError.unsupportedItem(reason: "textFileURL")
        case .convertedPNG:
            throw ShareInboxError.unsupportedItem(reason: "textImage")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ShareInboxError.unsupportedItem(reason: "emptyText")
        }
        guard value.utf8.count <= limits.maxTextBytes else {
            throw ShareInboxError.textTooLarge(byteCount: value.utf8.count, limit: limits.maxTextBytes)
        }
        return value
    }

    // MARK: Image

    @MainActor
    private static func loadImage(
        _ provider: NSItemProvider,
        temporaryRoot: URL,
        limits: ShareInboxLimits
    ) async throws -> ShareItemInput {
        let displayName = provider.suggestedName
        let registeredType = preferredTypeIdentifier(provider, conformingTo: .image)

        if let registeredType,
           let staged = try await fileRepresentationIfPossible(
            provider,
            typeIdentifier: registeredType,
            temporaryRoot: temporaryRoot,
            baseName: "image",
            fallbackExtension: UTType(registeredType)?.preferredFilenameExtension,
            limits: limits
           ) {
            let resolvedName = displayName ?? staged.originalName ?? staged.url.lastPathComponent
            return .file(
                staged.url,
                displayName: resolvedName,
                typeIdentifier: ShareProviderIntakePolicy.refinedTypeIdentifier(
                    requestedTypeIdentifier: registeredType,
                    originalFileName: resolvedName
                ),
                kind: .image
            )
        }

        let typeIdentifier = registeredType ?? UTType.image.identifier
        let fallbackExtension = UTType(typeIdentifier)?.preferredFilenameExtension
        let loaded = try await loadItem(
            provider,
            typeIdentifier: typeIdentifier,
            retainFileURLsInto: temporaryRoot,
            baseName: "image",
            fallbackExtension: fallbackExtension,
            limits: limits
        )
        switch loaded {
        case .retainedFile(let staged):
            let resolvedName = displayName ?? staged.originalName ?? staged.url.lastPathComponent
            return .file(
                staged.url,
                displayName: resolvedName,
                typeIdentifier: ShareProviderIntakePolicy.refinedTypeIdentifier(
                    requestedTypeIdentifier: typeIdentifier,
                    originalFileName: resolvedName
                ),
                kind: .image
            )
        case .url(let url):
            let destination = temporaryPath(
                temporaryRoot: temporaryRoot,
                baseName: "image",
                sourceExtension: url.pathExtension,
                fallbackExtension: fallbackExtension
            )
            try ShareInbox.copyFileBounded(
                from: url,
                to: destination,
                maxBytes: limits.maxItemBytes
            )
            return .file(
                destination,
                displayName: displayName ?? url.lastPathComponent,
                typeIdentifier: typeIdentifier,
                kind: .image
            )
        case .data(let data):
            guard data.count <= limits.maxItemBytes else {
                throw ShareInboxError.itemTooLarge(byteCount: data.count, limit: limits.maxItemBytes)
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
            let png = try ImageEncoding.boundedPNG(from: data, maxBytes: limits.maxItemBytes)
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
        temporaryRoot: URL,
        limits: ShareInboxLimits
    ) async throws -> ShareItemInput {
        let displayName = provider.suggestedName
        let fallbackExtension = UTType(typeIdentifier)?.preferredFilenameExtension
        if let staged = try await fileRepresentationIfPossible(
            provider,
            typeIdentifier: typeIdentifier,
            temporaryRoot: temporaryRoot,
            baseName: "file",
            fallbackExtension: fallbackExtension,
            limits: limits
        ) {
            let resolvedName = displayName ?? staged.originalName ?? staged.url.lastPathComponent
            return .file(
                staged.url,
                displayName: resolvedName,
                typeIdentifier: ShareProviderIntakePolicy.refinedTypeIdentifier(
                    requestedTypeIdentifier: typeIdentifier,
                    originalFileName: resolvedName
                ),
                kind: .file
            )
        }

        // Providers that only support `loadItem` may hand back the original
        // file URL here. A file: URL is retained INSIDE this first callback;
        // copying after the callback returned would race the provider's
        // transient coordinated location.
        let loaded = try await loadItem(
            provider,
            typeIdentifier: typeIdentifier,
            retainFileURLsInto: temporaryRoot,
            baseName: "file",
            fallbackExtension: fallbackExtension,
            limits: limits
        )
        switch loaded {
        case .retainedFile(let staged):
            return fileInput(
                staged: staged,
                provider: provider,
                requestedTypeIdentifier: typeIdentifier
            )
        case .url(let url):
            let destination = temporaryPath(
                temporaryRoot: temporaryRoot,
                baseName: "file",
                sourceExtension: url.pathExtension,
                fallbackExtension: fallbackExtension
            )
            try ShareInbox.copyFileBounded(from: url, to: destination, maxBytes: limits.maxItemBytes)
            return .file(
                destination,
                displayName: displayName ?? url.lastPathComponent,
                typeIdentifier: typeIdentifier,
                kind: .file
            )
        case .data(let data):
            guard data.count <= limits.maxItemBytes else {
                throw ShareInboxError.itemTooLarge(byteCount: data.count, limit: limits.maxItemBytes)
            }
            return .data(
                data,
                displayName: displayName,
                typeIdentifier: typeIdentifier,
                kind: .file
            )
        case .convertedPNG(let png):
            guard png.count <= limits.maxItemBytes else {
                throw ShareInboxError.itemTooLarge(byteCount: png.count, limit: limits.maxItemBytes)
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
        case retainedFile(StagedRepresentation)
        case convertedPNG(Data)
    }

    /// Outcome of loading a URL representation exactly once: either the
    /// file: location's bytes were retained inside the provider callback,
    /// or the value is a preservable (non-file) URL string.
    private enum URLRepresentationResult: Sendable {
        case retainedFile(StagedRepresentation)
        case textURL(String)
    }

    /// A file retained inside a provider callback: the extension-owned copy
    /// plus the original last path component observed in the callback.
    private struct StagedRepresentation: Sendable {
        let url: URL
        let originalName: String?
    }

    /// Loads the `public.url`-family representation in one `loadItem`
    /// callback. The value may arrive as URL/NSURL or as a String/text/
    /// UTF-8 data representation of the location; a file: value has its
    /// coordinated bytes retained inside this same callback, before the
    /// provider can revoke the transient path. Non-file strings keep the
    /// previous text-URL behavior (empty/limit checks included) and are
    /// never dereferenced.
    @MainActor
    private static func loadURLRepresentation(
        _ provider: NSItemProvider,
        typeIdentifier: String,
        temporaryRoot: URL,
        limits: ShareInboxLimits
    ) async throws -> URLRepresentationResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URLRepresentationResult, Error>) in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let urlValue: URL?
                if let url = item as? URL {
                    urlValue = url
                } else if let url = item as? NSURL {
                    urlValue = url as URL
                } else {
                    urlValue = nil
                }
                if let urlValue {
                    if urlValue.isFileURL {
                        continuation.resume(
                            with: retainedResult(urlValue, temporaryRoot: temporaryRoot, limits: limits)
                        )
                    } else {
                        continuation.resume(
                            with: textURLResult(urlValue.absoluteString, limits: limits)
                        )
                    }
                    return
                }

                // String / attributed text / UTF-8 data URL delivery.
                let text: String?
                var undecodableData = false
                if let string = item as? String {
                    text = string
                } else if let string = item as? NSString {
                    text = string as String
                } else if let attributed = item as? NSAttributedString {
                    text = attributed.string
                } else if let data = item as? Data {
                    text = String(data: data, encoding: .utf8)
                    undecodableData = text == nil
                } else if let data = item as? NSData {
                    text = String(data: data as Data, encoding: .utf8)
                    undecodableData = text == nil
                } else {
                    text = nil
                }
                if let text {
                    if ShareProviderIntakePolicy.disposition(forURLString: text) == .attemptFileRepresentation,
                       let fileURL = URL(string: text), fileURL.isFileURL {
                        continuation.resume(
                            with: retainedResult(fileURL, temporaryRoot: temporaryRoot, limits: limits)
                        )
                    } else {
                        continuation.resume(with: textURLResult(text, limits: limits))
                    }
                    return
                }
                if undecodableData {
                    continuation.resume(
                        throwing: ShareInboxError.unsupportedItem(reason: "textEncoding")
                    )
                    return
                }
                if item is UIImage {
                    continuation.resume(
                        throwing: ShareInboxError.unsupportedItem(reason: "textImage")
                    )
                    return
                }
                continuation.resume(
                    throwing: ShareInboxError.unsupportedItem(reason: "loadedItem")
                )
            }
        }
    }

    /// Retains a provider file URL's bytes inside the current callback:
    /// security-scoped access + `NSFileCoordinator` + bounded streaming copy
    /// into this process's temporary directory. Size and disk failures
    /// surface unchanged; anything else is an honest unreadable-file
    /// rejection — the transient location is never committed as text.
    private static func retainedResult(
        _ url: URL,
        temporaryRoot: URL,
        limits: ShareInboxLimits
    ) -> Result<URLRepresentationResult, Error> {
        do {
            let staged = try retainFileURL(
                url,
                temporaryRoot: temporaryRoot,
                baseName: "file",
                fallbackExtension: nil,
                limits: limits
            )
            return .success(.retainedFile(staged))
        } catch let error as ShareInboxError {
            switch error {
            case .itemTooLarge, .insufficientSpace, .textTooLarge:
                return .failure(error)
            default:
                return .failure(ShareInboxError.unsupportedItem(reason: "fileURLUnreadable"))
            }
        } catch {
            return .failure(ShareInboxError.unsupportedItem(reason: "fileURLUnreadable"))
        }
    }

    private static func textURLResult(
        _ value: String,
        limits: ShareInboxLimits
    ) -> Result<URLRepresentationResult, Error> {
        Result {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ShareInboxError.unsupportedItem(reason: "emptyText")
            }
            guard value.utf8.count <= limits.maxTextBytes else {
                throw ShareInboxError.textTooLarge(byteCount: value.utf8.count, limit: limits.maxTextBytes)
            }
            return .textURL(value)
        }
    }

    @MainActor
    private static func loadItem(
        _ provider: NSItemProvider,
        typeIdentifier: String,
        retainFileURLsInto temporaryRoot: URL?,
        baseName: String = "file",
        fallbackExtension: String? = nil,
        limits: ShareInboxLimits
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
                let url: URL?
                if let value = item as? URL {
                    url = value
                } else if let value = item as? NSURL {
                    url = value as URL
                } else {
                    url = nil
                }
                if let url {
                    if let temporaryRoot, url.isFileURL {
                        // File-lifetime contract: any file URL handed back
                        // by a provider is copied to this process's own
                        // temporary directory INSIDE the callback that
                        // delivered it.
                        continuation.resume(
                            with: Result {
                                try .retainedFile(
                                    retainFileURL(
                                        url,
                                        temporaryRoot: temporaryRoot,
                                        baseName: baseName,
                                        fallbackExtension: fallbackExtension,
                                        limits: limits
                                    )
                                )
                            }
                        )
                        return
                    }
                    continuation.resume(returning: .url(url))
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
                            maxBytes: limits.maxItemBytes
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
        fallbackExtension: String?,
        limits: ShareInboxLimits
    ) async throws -> StagedRepresentation? {
        do {
            return try await copyFileRepresentation(
                provider,
                typeIdentifier: typeIdentifier,
                temporaryRoot: temporaryRoot,
                baseName: baseName,
                fallbackExtension: fallbackExtension,
                limits: limits
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
        fallbackExtension: String?,
        limits: ShareInboxLimits
    ) async throws -> StagedRepresentation {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StagedRepresentation, Error>) in
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
                continuation.resume(
                    with: Result {
                        try retainFileURL(
                            url,
                            temporaryRoot: temporaryRoot,
                            baseName: baseName,
                            fallbackExtension: fallbackExtension,
                            limits: limits
                        )
                    }
                )
            }
        }
    }

    /// Shared in-callback retention boundary: security-scoped access +
    /// `NSFileCoordinator` + `ShareInbox.copyFileBounded` (bounded streaming
    /// copy; symlink/directory/oversize failures surface honestly).
    private static func retainFileURL(
        _ url: URL,
        temporaryRoot: URL,
        baseName: String,
        fallbackExtension: String?,
        limits: ShareInboxLimits
    ) throws -> StagedRepresentation {
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
                    maxBytes: limits.maxItemBytes
                )
            } catch {
                box.error = error
            }
        }
        if let error = box.error {
            throw error
        }
        if let coordinationError {
            throw coordinationError
        }
        return StagedRepresentation(url: destination, originalName: url.lastPathComponent)
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
