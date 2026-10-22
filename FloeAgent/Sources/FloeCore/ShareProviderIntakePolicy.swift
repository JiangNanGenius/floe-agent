// SPDX-License-Identifier: MPL-2.0
//
// FloeCore — Share provider intake policy (S5 P1 file-URL closure).
//
// Pure decision logic shared by the FloeShare extension's provider loader
// and its regression tests. It exists because a file share from another app
// can advertise ONE NSItemProvider whose representations include both a real
// file payload and a public.url location, and a loader that tests
// `public.url` first commits the transient file:// path as URL text instead
// of the file. A provider file URL points at the source app's transient
// coordinated location; the main App can neither open nor trust that path
// after the share ends, so committing it is a producer defect, not a
// successful file share.
//
// The policy keeps three promises:
// 1. When a provider advertises a real file representation together with a
//    URL representation, the file representation wins — the loader copies
//    the original bytes through that representation inside the provider
//    callback and records the concrete type of the retained original.
// 2. Genuine http/https web page URL strings (and other non-file URL or
//    text inputs) keep the exact previous text-URL behavior. Nothing here
//    dereferences a network location.
// 3. A file:// URL string is never preservable text: the loader must obtain
//    a coordinated copy within the provider callback lifetime or reject the
//    item honestly. Its transient location is never committed.

import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers

/// Disposition for a `public.url` string when the provider advertised no
/// concrete file representation of its own.
public enum ShareURLIntakeDisposition: String, Equatable, Sendable {
    /// Keep the string exactly as the shared web page / URL text input.
    case preserveTextURL
    /// The string is a file location. Its bytes must be copied through a
    /// provider representation load (or an in-callback coordinated read),
    /// or the item must be rejected. Never commit this location as text.
    case attemptFileRepresentation
}

public enum ShareProviderIntakePolicy {
    /// Identifiers that describe "some item" rather than a concrete payload
    /// type. A concrete identifier (com.adobe.pdf, public.jpeg, …) is always
    /// preferred over these for representation loading, and public.file-url
    /// is preferred over the remaining generics because it names the real
    /// file instead of a type-erased container.
    private static let genericContainerIdentifiers: Set<String> = [
        "public.item",
        "public.content",
        "public.data",
        "public.url",
        "public.file-url"
    ]

    /// Companion representations of a web-page URL share, not file payloads.
    private static let excludedPayloadIdentifiers: Set<String> = [
        "com.apple.webbookmark",
        "com.apple.webbookmark-array",
        "public.bookmark-list"
    ]

    /// Returns the registered type identifier whose coordinated file
    /// representation the loader must copy for a provider that also conforms
    /// to `public.url`, or `nil` when the provider advertises no file
    /// payload (for example a Safari page share registering only
    /// public.url + public.plain-text).
    ///
    /// Selection order reflects the typical Preview/Files share shape
    /// [public.file-url, com.adobe.pdf, public.url, …] (representative
    /// synthetic identifiers; `registeredTypeIdentifiers` keeps
    /// registration order):
    /// 1. the first concrete non-generic payload identifier (com.adobe.pdf);
    /// 2. public.file-url when it is the only file representation;
    /// 3. the remaining generic content/data identifier in registration order.
    public static func preferredFileRepresentationTypeIdentifier(
        registeredTypeIdentifiers: [String]
    ) -> String? {
        var candidates: [String] = []
        candidates.reserveCapacity(registeredTypeIdentifiers.count)
        for identifier in registeredTypeIdentifiers {
            if excludedPayloadIdentifiers.contains(identifier) { continue }
            guard let type = UTType(identifier) else { continue }
            // A textual payload is not a file share; Safari's URL+text
            // companion must keep its current de-duplication behavior. A
            // genuine text/html FILE share still carries public.file-url,
            // which the file-url fallback below selects, so text exclusion
            // here cannot turn a file into a dropped share.
            if type.conforms(to: .text) { continue }
            // Bookmarks/property lists accompany web-page URLs; loading them
            // would replace the page URL with a derived container file.
            if type.conforms(to: .propertyList) { continue }
            // The generic public.url is the location itself, not file bytes.
            // public.file-url is the url-family exception: it names a file.
            if type.conforms(to: .url), !type.conforms(to: .fileURL) { continue }
            candidates.append(identifier)
        }
        if let concrete = candidates.first(where: {
            !genericContainerIdentifiers.contains($0)
        }) {
            return concrete
        }
        if candidates.contains(UTType.fileURL.identifier) {
            return UTType.fileURL.identifier
        }
        return candidates.first(where: { $0 != UTType.url.identifier })
    }

    /// Classifies a loaded public.url string. Only the scheme is inspected;
    /// parsing never dereferences the location, network or otherwise.
    /// Strings that do not parse as a URL at all keep the previous
    /// text-URL behavior.
    public static func disposition(forURLString string: String) -> ShareURLIntakeDisposition {
        guard let url = URL(string: string), url.scheme?.lowercased() == "file" else {
            return .preserveTextURL
        }
        // Percent-encoded absolute paths, "file:/path" and empty-authority
        // forms are all still file locations and all equally preservable.
        return .attemptFileRepresentation
    }

    /// Refines a generic or file-url representation identifier into the
    /// concrete type of the retained original when its name carries an
    /// extension (for example "public.file-url" + "Example Domain.pdf" →
    /// "com.adobe.pdf"). A concrete requested type is never rewritten, so
    /// provider-declared types survive untouched.
    public static func refinedTypeIdentifier(
        requestedTypeIdentifier: String,
        originalFileName: String?
    ) -> String {
        guard genericContainerIdentifiers.contains(requestedTypeIdentifier),
              let originalFileName else { return requestedTypeIdentifier }
        let components = originalFileName.split(separator: ".")
        guard components.count >= 2,
              let ext = components.last,
              !ext.isEmpty,
              let concrete = UTType(filenameExtension: ext.lowercased()),
              !concrete.conforms(to: .url),
              !concrete.conforms(to: .propertyList) else {
            return requestedTypeIdentifier
        }
        return concrete.identifier
    }
}
#endif
