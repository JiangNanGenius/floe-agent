// FloeCoreTests — Share provider intake policy (S5 P1 file-URL closure).
//
// PREPARED DEFINITIONS — deliberately NOT executed in this lane (no compile
// authorized); run via `swift test --filter ShareProviderIntakePolicyTests`.
// Background: a Preview-style "Share → Floe Agent" of a saved PDF can
// advertise ONE NSItemProvider with public.file-url + com.adobe.pdf +
// public.url representations, and a loader that tests public.url first
// commits only the transient file:// location as URL text, with no retained
// file. The identifier set below is a REPRESENTATIVE SYNTHETIC regression
// shape (the exact advertisement of one specific system share was not
// captured); these tests pin the corrected selection policy with synthetic
// identifiers only.

#if canImport(UniformTypeIdentifiers)
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import FloeCore

@Suite("FloeCore.ShareProviderIntakePolicy")
struct ShareProviderIntakePolicyTests {

    // MARK: Preview-shaped file share

    @Test("A PDF share advertising file-url + pdf + url prefers the concrete PDF representation")
    func previewShapedPDFShareSelectsPDFBytes() {
        let selected = ShareProviderIntakePolicy.preferredFileRepresentationTypeIdentifier(
            registeredTypeIdentifiers: [
                "public.file-url",
                "com.adobe.pdf",
                "public.url"
            ]
        )
        #expect(selected == "com.adobe.pdf")
    }

    @Test("Selection is stable under registered-identifier order")
    func selectionStableUnderOrder() {
        let swapped = ShareProviderIntakePolicy.preferredFileRepresentationTypeIdentifier(
            registeredTypeIdentifiers: [
                "public.url",
                "public.file-url",
                "com.adobe.pdf"
            ]
        )
        #expect(swapped == "com.adobe.pdf")
        let genericLast = ShareProviderIntakePolicy.preferredFileRepresentationTypeIdentifier(
            registeredTypeIdentifiers: [
                "com.adobe.pdf",
                "public.data",
                "public.url"
            ]
        )
        #expect(genericLast == "com.adobe.pdf")
    }

    @Test("A file advertised only as public.file-url is still a file payload")
    func fileURLOnlyIsFilePayload() {
        let selected = ShareProviderIntakePolicy.preferredFileRepresentationTypeIdentifier(
            registeredTypeIdentifiers: ["public.file-url", "public.url"]
        )
        #expect(selected == "public.file-url")
    }

    @Test("Generic content/data representations remain selectable")
    func genericContentSelectable() {
        #expect(ShareProviderIntakePolicy.preferredFileRepresentationTypeIdentifier(
            registeredTypeIdentifiers: ["public.data", "public.url"]
        ) == "public.data")
        #expect(ShareProviderIntakePolicy.preferredFileRepresentationTypeIdentifier(
            registeredTypeIdentifiers: ["public.url", "public.content"]
        ) == "public.content")
    }

    @Test("HTML/text file shares are intaken via file-url, not dropped as text twins")
    func textTypedFileShareStillSelectsFileURL() {
        let selected = ShareProviderIntakePolicy.preferredFileRepresentationTypeIdentifier(
            registeredTypeIdentifiers: ["public.file-url", "public.html", "public.url"]
        )
        #expect(selected == "public.file-url")
    }

    // MARK: Genuine web page shares keep the old URL behavior

    @Test("Safari web page shares (public.url + public.plain-text) advertise no file representation")
    func safariWebPageHasNoFileRepresentation() {
        let selected = ShareProviderIntakePolicy.preferredFileRepresentationTypeIdentifier(
            registeredTypeIdentifiers: ["public.url", "public.plain-text"]
        )
        #expect(selected == nil)
    }

    @Test("Web bookmarks accompany a URL and are not loaded as file payloads")
    func bookmarksAreNotFilePayloads() {
        #expect(ShareProviderIntakePolicy.preferredFileRepresentationTypeIdentifier(
            registeredTypeIdentifiers: ["com.apple.webbookmark", "public.url"]
        ) == nil)
        #expect(ShareProviderIntakePolicy.preferredFileRepresentationTypeIdentifier(
            registeredTypeIdentifiers: ["public.url"]
        ) == nil)
    }

    @Test("Unknown identifiers are ignored without crashing the selection")
    func unknownIdentifiersIgnored() {
        #expect(ShareProviderIntakePolicy.preferredFileRepresentationTypeIdentifier(
            registeredTypeIdentifiers: ["not.a.utype", "public.url"]
        ) == nil)
    }

    // MARK: URL string disposition

    @Test("file: strings must never be preserved as URL text")
    func fileURLStringsRequireRetainedBytes() {
        #expect(ShareProviderIntakePolicy.disposition(
            forURLString: "file:///private/tmp/Example%20Domain.pdf"
        ) == .attemptFileRepresentation)
        #expect(ShareProviderIntakePolicy.disposition(
            forURLString: "file:/private/tmp/ghost.pdf"
        ) == .attemptFileRepresentation)
        #expect(ShareProviderIntakePolicy.disposition(
            forURLString: "FILE:///private/tmp/x.pdf"
        ) == .attemptFileRepresentation)
    }

    @Test("http/https and other strings keep the previous text-URL behavior")
    func nonFileStringsPreserved() {
        #expect(ShareProviderIntakePolicy.disposition(
            forURLString: "https://example.com/"
        ) == .preserveTextURL)
        #expect(ShareProviderIntakePolicy.disposition(
            forURLString: "http://example.com/a?b=1"
        ) == .preserveTextURL)
        #expect(ShareProviderIntakePolicy.disposition(
            forURLString: "mailto:someone@example.com"
        ) == .preserveTextURL)
        #expect(ShareProviderIntakePolicy.disposition(
            forURLString: "not a url at all"
        ) == .preserveTextURL)
    }

    // MARK: Type refinement of the retained original

    @Test("Generic/file-url identifiers are refined to the concrete type of the retained name")
    func refinement() {
        #expect(ShareProviderIntakePolicy.refinedTypeIdentifier(
            requestedTypeIdentifier: "public.file-url",
            originalFileName: "Example Domain.pdf"
        ) == "com.adobe.pdf")
        #expect(ShareProviderIntakePolicy.refinedTypeIdentifier(
            requestedTypeIdentifier: "public.url",
            originalFileName: "Example Domain.pdf"
        ) == "com.adobe.pdf")
        #expect(ShareProviderIntakePolicy.refinedTypeIdentifier(
            requestedTypeIdentifier: "public.file-url",
            originalFileName: "notes.txt"
        ) == "public.plain-text")
        // Concrete requested types are never rewritten.
        #expect(ShareProviderIntakePolicy.refinedTypeIdentifier(
            requestedTypeIdentifier: "com.adobe.pdf",
            originalFileName: "renamed.docx"
        ) == "com.adobe.pdf")
        // Names without extensions, or with unknown extensions, keep the
        // requested generic identifier.
        #expect(ShareProviderIntakePolicy.refinedTypeIdentifier(
            requestedTypeIdentifier: "public.file-url",
            originalFileName: "noextension"
        ) == "public.file-url")
        #expect(ShareProviderIntakePolicy.refinedTypeIdentifier(
            requestedTypeIdentifier: "public.file-url",
            originalFileName: nil
        ) == "public.file-url")
    }
}
#endif
