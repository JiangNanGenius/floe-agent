// FloeAppTests — FloeShare provider loader regressions (S5 P1 file-URL closure).
//
// PREPARED DEFINITIONS — deliberately NOT executed in this lane (no compile
// authorized). The unified qualification run owns execution after the primary
// applies the project.yml membership lines from this lane's patch.
//
// These tests drive the REAL extracted `ShareItemProviderLoader` (compiled
// into this bundle via project.yml, the same way the FloeFileProvider
// extension sources are compiled) with REAL NSItemProvider instances using
// the registration spelling of the current iOS SDK: `NSItemProvider.h`
// exposes `registerItemForTypeIdentifier:loadHandler:` whose
// `NSItemProviderLoadHandler` is a THREE-parameter block
// (completionHandler, expectedValueClass, options). The provider-side lazy
// registration plus the consumer-side `loadItem`/`loadFileRepresentation`
// pair mirrors the coercion interface a real source app uses. Both provider
// APIs are deprecated-but-available in the 27.x SDK; deprecation warnings
// here are expected and do not mute any production error assertion.
//
// Fixture honesty: the real system share that exposed the original defect
// committed a file:// location as URL text with no retained bytes; its exact
// registered-identifier advertisement was NOT captured. The
// [public.file-url, com.adobe.pdf, public.url] shape below is a
// REPRESENTATIVE SYNTHETIC regression shape, not an observed capture.
//
// Callback lifetime: an NSItemProvider file location is only valid for
// coordinated reading inside the provider callback. The lazy registration
// handler may deliver the value synchronously or asynchronously, so a
// synthetic provider cannot observe the real revocation moment. The tests
// therefore pin the loader's structural contract instead: each intake
// consults the payload representation AT MOST once (never a
// load-string → representation → re-load chain as a lifetime workaround),
// and the retained bytes/digest survive removal of the source file before
// any later consumer reads it.
//
// Synthetic content only; no real user file and no private paths.

#if canImport(UIKit)
import Foundation
import UIKit
import UniformTypeIdentifiers
import Testing
import FloeCore

// MARK: - Deterministic synthetic payload

/// A deterministic, bounded, PDF-prefixed payload. The loader never parses
/// PDF structure; the header only keeps the fixture honest about being a PDF.
private let syntheticPDFBytes: Data = {
    var bytes = [UInt8]()
    bytes.append(contentsOf: Array("%PDF-1.4\n".utf8))
    for index in 0..<4_096 {
        bytes.append(UInt8(index % 251))
    }
    bytes.append(contentsOf: Array("%%EOF\n".utf8))
    return Data(bytes)
}()

private let syntheticPDFTypeIdentifier = "com.adobe.pdf"

/// Counts how often each lazily registered representation is consulted,
/// which pins the "load the payload once, retain inside the callback"
/// boundary without depending on private loader code.
private final class RepresentationRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(_ identifier: String) {
        lock.lock()
        counts[identifier, default: 0] += 1
        lock.unlock()
    }

    func count(for identifier: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[identifier] ?? 0
    }
}

private func makeScratchDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("share-loader-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes the source PDF into `directory` and returns its URL.
private func writeSyntheticPDF(in directory: URL, name: String = "Example Domain.pdf") throws -> URL {
    let url = directory.appendingPathComponent(name)
    try syntheticPDFBytes.write(to: url)
    return url
}

/// Registers one lazy representation on a real NSItemProvider with the
/// current SDK `registerItem(forTypeIdentifier:loadHandler:)` spelling:
/// the handler receives (completionHandler, expectedValueClass, options).
@MainActor
private func register(
    _ provider: NSItemProvider,
    typeIdentifier: String,
    requests: RepresentationRequests? = nil,
    object: @escaping @Sendable () -> any NSSecureCoding
) {
    provider.registerItem(forTypeIdentifier: typeIdentifier) { completion, _, _ in
        requests?.record(typeIdentifier)
        completion?(object(), nil)
    }
}

/// Preview-shaped PDF share: [public.file-url, com.adobe.pdf, public.url].
/// `pdfObject` lets a fixture vend the PDF representation as file DATA
/// (representation load succeeds) or as a file URL (representation fails →
/// the loader must retain inside the loadItem callback).
@MainActor
private func makePDFProvider(
    sourceURL: URL,
    advertising representations: [String],
    pdfVendedAsURL: Bool = false,
    suggestedName: String? = "Example Domain.pdf",
    requests: RepresentationRequests? = nil
) -> NSItemProvider {
    let provider = NSItemProvider()
    if let suggestedName {
        provider.suggestedName = suggestedName
    }
    for identifier in representations {
        if identifier == syntheticPDFTypeIdentifier, !pdfVendedAsURL {
            register(provider, typeIdentifier: identifier, requests: requests) {
                syntheticPDFBytes as NSData
            }
        } else {
            register(provider, typeIdentifier: identifier, requests: requests) {
                sourceURL as NSURL
            }
        }
    }
    return provider
}

@MainActor
private func extensionItem(_ providers: [NSItemProvider]) -> NSExtensionItem {
    let item = NSExtensionItem()
    item.attachments = providers
    return item
}

private func expectFileInput(
    _ inputs: [ShareItemInput],
    count: Int = 1
) throws -> (url: URL, displayName: String?, typeIdentifier: String, kind: ShareInboxItemKind) {
    #expect(inputs.count == count)
    guard case .file(let url, let displayName, let typeIdentifier, let kind) = inputs.first else {
        Issue.record("expected a .file input, got \(String(describing: inputs.first))")
        throw ShareInboxError.unsupportedItem(reason: "testExpectation")
    }
    return (url, displayName, typeIdentifier, kind)
}

// MARK: - Suites

@MainActor
@Suite("FloeShare.ShareItemProviderLoader")
struct ShareItemProviderLoaderTests {

    /// Representative Preview-shape PDF share. Regression target for the
    /// original defect: the URL text of the transient file:// location was
    /// committed with no sha256 and no retained file. The generic URL
    /// representation must never even be consulted once the concrete file
    /// representation is selected.
    @Test("PDF share shape commits retained bytes, never a file URL string")
    func pdfShareShapeKeepsBytesThroughCommit() async throws {
        let sources = try makeScratchDirectory("sources")
        let tempRoot = try makeScratchDirectory("temp")
        let inboxRoot = try makeScratchDirectory("inbox")
        defer {
            try? FileManager.default.removeItem(at: sources)
            try? FileManager.default.removeItem(at: tempRoot)
            try? FileManager.default.removeItem(at: inboxRoot)
        }
        let sourceURL = try writeSyntheticPDF(in: sources)
        let requests = RepresentationRequests()
        let provider = makePDFProvider(
            sourceURL: sourceURL,
            advertising: [
                UTType.fileURL.identifier,   // public.file-url
                syntheticPDFTypeIdentifier,
                UTType.url.identifier        // public.url
            ],
            requests: requests
        )

        let inputs = try await ShareItemProviderLoader.loadInputs(
            from: [extensionItem([provider])],
            temporaryRoot: tempRoot
        )

        // The decisive regression: the old loader produced exactly ONE
        // .url input with the transient file:// text here — and it asked
        // the generic public.url representation FIRST.
        #expect(inputs.allSatisfy { if case .url = $0 { return false }; return true })
        #expect(requests.count(for: UTType.url.identifier) == 0)
        #expect(requests.count(for: UTType.fileURL.identifier) == 0)
        let staged = try expectFileInput(inputs)
        #expect(staged.kind == .file)
        #expect(staged.typeIdentifier == syntheticPDFTypeIdentifier)
        #expect(staged.displayName == "Example Domain.pdf")
        #expect(try Data(contentsOf: staged.url) == syntheticPDFBytes)

        // Remove the source, then finish the flow exactly like
        // ShareViewController does: the retained copy is already
        // extension-owned, so the committed envelope survives without it.
        try FileManager.default.removeItem(at: sourceURL)

        let inbox = ShareInbox(rootURL: inboxRoot)
        let session = try inbox.beginStaging(producer: "FloeShare")
        try session.adoptTemporaryFile(
            at: staged.url,
            displayName: staged.displayName,
            typeIdentifier: staged.typeIdentifier,
            kind: staged.kind
        )
        let envelope = try session.commit()

        let item = try #require(envelope.items.first)
        #expect(envelope.items.count == 1)
        #expect(item.kind == .file)
        #expect(item.fileName == "Example Domain.pdf")
        #expect(item.typeIdentifier == syntheticPDFTypeIdentifier)
        #expect(item.byteCount == syntheticPDFBytes.count)
        #expect(item.sha256 == FloeDigest.sha256Hex(syntheticPDFBytes))
        #expect(envelope.totalByteCount == syntheticPDFBytes.count)

        let payload = try inbox.payloadURL(for: item, in: envelope)
        #expect(try Data(contentsOf: payload) == syntheticPDFBytes)
        #expect(try inbox.pending().map(\.id) == [envelope.id])
    }

    /// Concrete PDF representation vended as a file URL (a provider whose
    /// loadFileRepresentation cannot serve the item): whichever internal
    /// representation load succeeds, the bytes must be retained inside the
    /// FIRST callback that yields the file URL, and the generic URL
    /// representation must not be re-queried as a lifetime workaround.
    @Test("PDF representation vended as a URL retains bytes/name/type/digest")
    func pdfRepresentationAsURLRetainsInsideFirstCallback() async throws {
        let sources = try makeScratchDirectory("sources")
        let tempRoot = try makeScratchDirectory("temp")
        defer {
            try? FileManager.default.removeItem(at: sources)
            try? FileManager.default.removeItem(at: tempRoot)
        }
        let sourceURL = try writeSyntheticPDF(in: sources)
        let requests = RepresentationRequests()
        let provider = makePDFProvider(
            sourceURL: sourceURL,
            advertising: [
                UTType.fileURL.identifier,
                syntheticPDFTypeIdentifier,
                UTType.url.identifier
            ],
            pdfVendedAsURL: true,
            suggestedName: nil,
            requests: requests
        )

        let inputs = try await ShareItemProviderLoader.loadInputs(
            from: [extensionItem([provider])],
            temporaryRoot: tempRoot
        )
        #expect(requests.count(for: UTType.url.identifier) == 0)
        let staged = try expectFileInput(inputs)
        #expect(staged.kind == .file)
        #expect(staged.typeIdentifier == syntheticPDFTypeIdentifier)
        // suggestedName is nil: the name retained inside the callback
        // (the source file's last path component) must survive.
        #expect(staged.displayName == "Example Domain.pdf")
        let retained = try Data(contentsOf: staged.url)
        #expect(retained == syntheticPDFBytes)
        #expect(FloeDigest.sha256Hex(retained) == FloeDigest.sha256Hex(syntheticPDFBytes))

        try FileManager.default.removeItem(at: sourceURL)
        #expect(try Data(contentsOf: staged.url) == syntheticPDFBytes)
    }

    /// A provider advertising ONLY public.file-url (+ its url supertype) is
    /// still a file share; the concrete type is refined from the retained
    /// original name.
    @Test("File-URL-only providers are copied and refined to the concrete type")
    func fileURLOnlyRefinesConcreteType() async throws {
        let sources = try makeScratchDirectory("sources")
        let tempRoot = try makeScratchDirectory("temp")
        defer {
            try? FileManager.default.removeItem(at: sources)
            try? FileManager.default.removeItem(at: tempRoot)
        }
        let sourceURL = try writeSyntheticPDF(in: sources)
        let provider = makePDFProvider(
            sourceURL: sourceURL,
            advertising: [UTType.fileURL.identifier, UTType.url.identifier]
        )

        let inputs = try await ShareItemProviderLoader.loadInputs(
            from: [extensionItem([provider])],
            temporaryRoot: tempRoot
        )
        let staged = try expectFileInput(inputs)
        #expect(staged.typeIdentifier == syntheticPDFTypeIdentifier)
        #expect(staged.displayName == "Example Domain.pdf")
        #expect(try Data(contentsOf: staged.url) == syntheticPDFBytes)
    }

    /// The proven defect shape: a bare public.url whose value is a file
    /// location, delivered as URL/NSURL. The loader must load the
    /// representation EXACTLY once, retain the bytes inside that first
    /// callback, and never commit the path as text.
    @Test("public.url callback delivering a file URL is retained with one request")
    func urlCallbackRetentionSurvivesSourceRemoval() async throws {
        let sources = try makeScratchDirectory("sources")
        let tempRoot = try makeScratchDirectory("temp")
        defer {
            try? FileManager.default.removeItem(at: sources)
            try? FileManager.default.removeItem(at: tempRoot)
        }
        let sourceURL = try writeSyntheticPDF(in: sources)
        let requests = RepresentationRequests()
        let provider = NSItemProvider()
        provider.suggestedName = "Example Domain.pdf"
        register(provider, typeIdentifier: UTType.url.identifier, requests: requests) {
            sourceURL as NSURL
        }

        let inputs = try await ShareItemProviderLoader.loadInputs(
            from: [extensionItem([provider])],
            temporaryRoot: tempRoot
        )
        // No load-string → loadFileRepresentation → re-loadItem chain.
        #expect(requests.count(for: UTType.url.identifier) == 1)
        #expect(inputs.allSatisfy { if case .url = $0 { return false }; return true })
        let staged = try expectFileInput(inputs)
        #expect(staged.typeIdentifier == syntheticPDFTypeIdentifier)
        #expect(staged.displayName == "Example Domain.pdf")
        #expect(try Data(contentsOf: staged.url) == syntheticPDFBytes)

        // The provider location is revoked: the retained copy is untouched.
        try FileManager.default.removeItem(at: sourceURL)
        #expect(try Data(contentsOf: staged.url) == syntheticPDFBytes)
    }

    /// The same file location may instead arrive as a String / attributed
    /// text / UTF-8 URL representation of the public.url value. It must be
    /// classified in-callback and retained, never persisted as path text.
    @Test("file: value delivered as URL text or UTF-8 data is retained, not persisted as text")
    func urlTextAndDataFormsAreRetained() async throws {
        let sources = try makeScratchDirectory("sources")
        let tempRoot = try makeScratchDirectory("temp")
        defer {
            try? FileManager.default.removeItem(at: sources)
            try? FileManager.default.removeItem(at: tempRoot)
        }
        let sourceURL = try writeSyntheticPDF(in: sources)

        let forms: [(label: String, object: @Sendable () -> any NSSecureCoding)] = [
            ("string", { sourceURL.absoluteString as NSString }),
            ("attributed", { NSAttributedString(string: sourceURL.absoluteString) }),
            ("utf8", { Data(sourceURL.absoluteString.utf8) as NSData })
        ]
        for (label, object) in forms {
            let provider = NSItemProvider()
            provider.suggestedName = "Example Domain.pdf"
            register(provider, typeIdentifier: UTType.url.identifier) { object() }

            let inputs = try await ShareItemProviderLoader.loadInputs(
                from: [extensionItem([provider])],
                temporaryRoot: tempRoot
            )
            let staged = try expectFileInput(inputs)
            #expect(staged.typeIdentifier == syntheticPDFTypeIdentifier, "URL representation: \(label)")
            #expect(try Data(contentsOf: staged.url) == syntheticPDFBytes, "URL representation: \(label)")
        }
        try FileManager.default.removeItem(at: sourceURL)
    }

    /// A provider that exposes public.url AND public.plain-text on the SAME
    /// attachment is the URL payload, not a "text twin": the actual URL must
    /// be kept (skipping this shape would silently drop the share).
    @Test("Same-provider URL + plain-text keeps the URL payload")
    func sameProviderURLAndTextIsNotSkipped() async throws {
        let tempRoot = try makeScratchDirectory("temp")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let pageURL = try #require(URL(string: "https://example.com/"))
        let requests = RepresentationRequests()
        let provider = NSItemProvider()
        register(provider, typeIdentifier: UTType.url.identifier, requests: requests) {
            pageURL as NSURL
        }
        register(provider, typeIdentifier: UTType.plainText.identifier, requests: requests) {
            "Example Domain" as NSString
        }

        let inputs = try await ShareItemProviderLoader.loadInputs(
            from: [extensionItem([provider])],
            temporaryRoot: tempRoot
        )
        #expect(inputs.count == 1)
        guard case .url(let value) = inputs.first else {
            Issue.record("expected a .url input")
            return
        }
        #expect(value == pageURL.absoluteString)
        // The plain-text companion of the same provider is not loaded twice.
        #expect(requests.count(for: UTType.plainText.identifier) == 0)
    }

    /// Genuine web page shares with a SEPARATE plain-text companion must
    /// keep the OLD behavior byte-for-byte: URL attachment kept, text twin
    /// skipped, no file attempt.
    @Test("Safari web page URL + separate text twin keeps the single text-URL input")
    func webPageURLBehaviorPreserved() async throws {
        let tempRoot = try makeScratchDirectory("temp")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let pageURL = try #require(URL(string: "https://example.com/"))
        let textRequests = RepresentationRequests()
        let urlProvider = NSItemProvider()
        register(urlProvider, typeIdentifier: UTType.url.identifier) { pageURL as NSURL }
        let textProvider = NSItemProvider()
        register(textProvider, typeIdentifier: UTType.plainText.identifier, requests: textRequests) {
            "Example Domain" as NSString
        }

        let inputs = try await ShareItemProviderLoader.loadInputs(
            from: [extensionItem([urlProvider, textProvider])],
            temporaryRoot: tempRoot
        )
        #expect(inputs.count == 1)
        guard case .url(let value) = inputs.first else {
            Issue.record("expected a .url input")
            return
        }
        #expect(value == pageURL.absoluteString)
        #expect(textRequests.count(for: UTType.plainText.identifier) == 0)
    }

    /// A public.url whose string resolves to a file: location for a MISSING
    /// file must be rejected honestly — its transient path must never be
    /// committed as a kind:url item.
    @Test("Missing file URL is rejected, never committed as URL text")
    func missingFileURLRejected() async throws {
        let tempRoot = try makeScratchDirectory("temp")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let ghostURL = URL(fileURLWithPath: "/no/such/dir-\(UUID().uuidString)/ghost.pdf")
        let provider = NSItemProvider()
        register(provider, typeIdentifier: UTType.url.identifier) { ghostURL as NSURL }

        await #expect(throws: ShareInboxError.unsupportedItem(reason: "fileURLUnreadable")) {
            _ = try await ShareItemProviderLoader.loadInputs(
                from: [extensionItem([provider])],
                temporaryRoot: tempRoot
            )
        }
    }

    /// A directory masquerading as a file URL is unsafe intake: rejected.
    @Test("Directory file URL is rejected instead of committed")
    func directoryFileURLRejected() async throws {
        let sources = try makeScratchDirectory("sources")
        let tempRoot = try makeScratchDirectory("temp")
        defer {
            try? FileManager.default.removeItem(at: sources)
            try? FileManager.default.removeItem(at: tempRoot)
        }
        let directoryURL = sources.appendingPathComponent("NotADocument", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let provider = NSItemProvider()
        register(provider, typeIdentifier: UTType.url.identifier) { directoryURL as NSURL }

        await #expect(throws: ShareInboxError.unsupportedItem(reason: "fileURLUnreadable")) {
            _ = try await ShareItemProviderLoader.loadInputs(
                from: [extensionItem([provider])],
                temporaryRoot: tempRoot
            )
        }
    }

    /// Oversized intake still fails bounded, with the original size error
    /// surfaced (never hidden as "unavailable bytes").
    @Test("Oversized PDF share reports itemTooLarge")
    func oversizedShareStillRejected() async throws {
        let sources = try makeScratchDirectory("sources")
        let tempRoot = try makeScratchDirectory("temp")
        defer {
            try? FileManager.default.removeItem(at: sources)
            try? FileManager.default.removeItem(at: tempRoot)
        }
        let sourceURL = try writeSyntheticPDF(in: sources)
        let provider = makePDFProvider(
            sourceURL: sourceURL,
            advertising: [
                UTType.fileURL.identifier,
                syntheticPDFTypeIdentifier,
                UTType.url.identifier
            ]
        )
        let limits = ShareInboxLimits(
            maxItems: 5,
            maxTextBytes: 4_096,
            maxItemBytes: 64,
            maxEnvelopeBytes: 1_048_576
        )

        await #expect(throws: ShareInboxError.itemTooLarge(
            byteCount: syntheticPDFBytes.count,
            limit: 64
        )) {
            _ = try await ShareItemProviderLoader.loadInputs(
                from: [extensionItem([provider])],
                temporaryRoot: tempRoot,
                limits: limits
            )
        }
    }

    /// The bounded five-item admission is unchanged.
    @Test("Six URL providers reject the whole share with itemLimitExceeded")
    func fiveItemCapPreserved() async throws {
        let tempRoot = try makeScratchDirectory("temp")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let pageURL = try #require(URL(string: "https://example.com/"))
        let items = (0..<6).map { _ in
            let provider = NSItemProvider()
            register(provider, typeIdentifier: UTType.url.identifier) { pageURL as NSURL }
            return extensionItem([provider])
        }

        await #expect(throws: ShareInboxError.itemLimitExceeded(limit: 5)) {
            _ = try await ShareItemProviderLoader.loadInputs(
                from: items,
                temporaryRoot: tempRoot
            )
        }
    }

    /// Cancellation semantics: bytes already retained inside the callback are
    /// discarded WITHOUT a readable envelope when the session is cancelled —
    /// matching the sheet-dismiss path in ShareViewController.
    @Test("Cancelled staging after loader retains no readable envelope")
    func cancelledStagingLeavesNothingReadable() async throws {
        let sources = try makeScratchDirectory("sources")
        let tempRoot = try makeScratchDirectory("temp")
        let inboxRoot = try makeScratchDirectory("inbox")
        defer {
            try? FileManager.default.removeItem(at: sources)
            try? FileManager.default.removeItem(at: tempRoot)
            try? FileManager.default.removeItem(at: inboxRoot)
        }
        let sourceURL = try writeSyntheticPDF(in: sources)
        let provider = makePDFProvider(
            sourceURL: sourceURL,
            advertising: [
                UTType.fileURL.identifier,
                syntheticPDFTypeIdentifier,
                UTType.url.identifier
            ]
        )

        let inputs = try await ShareItemProviderLoader.loadInputs(
            from: [extensionItem([provider])],
            temporaryRoot: tempRoot
        )
        let staged = try expectFileInput(inputs)

        let inbox = ShareInbox(rootURL: inboxRoot)
        let session = try inbox.beginStaging(producer: "FloeShare")
        try session.adoptTemporaryFile(
            at: staged.url,
            displayName: staged.displayName,
            typeIdentifier: staged.typeIdentifier,
            kind: staged.kind
        )
        session.cancel()

        #expect(try inbox.pending().isEmpty)
        let staging = inboxRoot.appendingPathComponent(".staging", isDirectory: true)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: staging.path)
        #expect(leftovers.isEmpty)
    }
}
#endif
