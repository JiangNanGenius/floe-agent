// SPDX-License-Identifier: MPL-2.0
//
// Android public SkillHub transport-mirror router (CONTRACT_V1). Ported
// VERBATIM in behaviour from the reviewed iOS main sources
//   FloeAgent/Sources/FloeSkills/SkillHubMirrorTransport.swift
//     (main @ 2ce48570a, fixed git object)
//   FloeAgent/FloeApp/Workspace/SourceControlCenter.swift
//     (SkillHubPublicTransport compiled-route helpers + AtomCommitCollector,
//      main @ 2ce48570a, fixed git object)
// with Android-module naming only.
//
// Compiled, approved, anonymous byte routes for the official Hub
// (JiangNanGenius/floe-skill-hub). GitHub primary is ALWAYS first; the
// signed policy may only order or disable the already-compiled ghfast.top /
// gh-proxy.com identities per role. The caller's original repository,
// immutable commit, path, view and expected content identity stay fixed
// across every route. Authentication and signed-content checks stay with
// their existing callers, outside failover; no Authorization/cookie/secret
// header is ever forwarded to a mirror origin. Only bounded network/server
// availability failures (HTTP 408/429/500/502/503/504 or a typed URLError
// availability code) may advance to the next approved route for the SAME
// pinned file; access, certificate, redirect, size and integrity failures
// stop at the route that produced them.
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import FloeSkills

public enum AndroidHubMirrorTransport {
    public enum Failure: Error, Equatable, LocalizedError, Sendable {
        case invalidTarget
        case httpStatus(Int)
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .invalidTarget: "Skill Hub download target is invalid."
            case .httpStatus(let code): "Skill Hub download failed (HTTP \(code))."
            case .invalidResponse: "Skill Hub download response is invalid."
            }
        }
    }

    private static let atom = "https://github.com/JiangNanGenius/floe-skill-hub/commits/main.atom"
    private static let rawPrefix = "/JiangNanGenius/floe-skill-hub/"

    // MARK: - Compiled approved routes (bootstrap uses these only)

    /// The exact repository's Atom commit feed. Identity is not interpolated
    /// from caller input beyond the hub constants; `main` is the only ref
    /// this feed resolves.
    public static func atomURL(owner: String, repository: String) -> URL? {
        guard owner == CuratedSkillHub.owner, repository == CuratedSkillHub.repository else { return nil }
        return URL(string: "https://github.com/\(owner)/\(repository)/commits/main.atom")
    }

    /// Immutable raw-file URL at a pinned commit. Only safe relative paths
    /// are accepted: non-empty unreserved segments, no dot segments, no
    /// backslash, percent, query or fragment bytes, no leading slash. No
    /// `main`-branch file URL is ever constructed here.
    public static func rawFileURL(owner: String, repository: String, commit: String, path: String) -> URL? {
        guard owner == CuratedSkillHub.owner, repository == CuratedSkillHub.repository,
              isCanonicalCommit(commit), !path.isEmpty, !path.hasPrefix("/"),
              !path.contains("\\"), !path.contains("%"), !path.contains("?"), !path.contains("#")
        else { return nil }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~+")
        for segment in segments {
            guard !segment.isEmpty, segment != ".", segment != "..",
                  segment.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        }
        let encoding = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        let encoded = segments.compactMap { String($0).addingPercentEncoding(withAllowedCharacters: encoding) }
        guard encoded.count == segments.count else { return nil }
        return URL(string: "https://raw.githubusercontent.com/\(owner)/\(repository)/\(commit)/"
            + encoded.joined(separator: "/"))
    }

    /// Canonical immutable GitHub commit object ID: exactly 40 lowercase hex
    /// ASCII bytes, matching the production publication-commit gate.
    public static func isCanonicalCommit(_ ref: String) -> Bool {
        ref.utf8.count == 40 && ref.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    // MARK: - Route candidates

    /// The mutable Atom resolver has only the mirror actually supporting it.
    /// File routes always preserve the exact immutable commit and path.
    public static func candidates(for canonical: URL,
                                  roles: AndroidHubMirrorRoles = .bundled) -> [URL] {
        guard let parts = URLComponents(url: canonical, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.port == nil,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return [] }
        let mirrors: [String]
        if canonical.absoluteString == atom {
            mirrors = roles.atom.map(\.prefix)
        } else {
            guard parts.host == "raw.githubusercontent.com",
                  parts.percentEncodedPath.hasPrefix(rawPrefix) else { return [] }
            let tail = parts.percentEncodedPath.dropFirst(rawPrefix.count)
                .split(separator: "/", omittingEmptySubsequences: false)
            guard tail.count >= 2, tail[0].utf8.count == 40,
                  tail[0].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { return [] }
            let plain = CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
            let allowed = plain.union(CharacterSet(charactersIn: "+"))
            for segment in tail.dropFirst() {
                guard let decoded = String(segment).removingPercentEncoding,
                      !decoded.isEmpty, decoded != ".", decoded != "..",
                      decoded.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                      decoded.addingPercentEncoding(withAllowedCharacters: plain) == String(segment)
                else { return [] }
            }
            mirrors = roles.rawFiles.map(\.prefix)
        }
        return [canonical] + mirrors.compactMap { URL(string: $0 + canonical.absoluteString) }
    }

    /// Only definite transport availability errors are retried. Access,
    /// certificate, redirect, content/size and integrity failures stop here.
    public static func isAvailabilityFailure(_ error: Error) -> Bool {
        if case Failure.httpStatus(let status) = error {
            return [408, 429, 500, 502, 503, 504].contains(status)
        }
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    public static func load(
        _ canonical: URL,
        roles: AndroidHubMirrorRoles = .bundled,
        request: @Sendable (URL) async throws -> Data
    ) async throws -> Data {
        let routes = candidates(for: canonical, roles: roles)
        guard !routes.isEmpty else { throw Failure.invalidTarget }
        for (index, route) in routes.enumerated() {
            try Task.checkCancellation()
            do {
                let bytes = try await request(route)
                try Task.checkCancellation()
                return bytes
            } catch {
                try Task.checkCancellation()
                guard index + 1 < routes.count, isAvailabilityFailure(error) else { throw error }
            }
        }
        throw Failure.invalidResponse
    }
}

// MARK: - Atom commit extraction (compiled bootstrap route)

/// First Atom entry → canonical commit SHA, cross-checked against that
/// entry's own commit link so the feed-level id, a different repository's
/// entry or a mismatched link is never accepted as a commit. External
/// entity declarations are rejected before parsing, and the parser never
/// resolves external resources.
public enum AndroidHubAtomCommit {
    private static let commitTagPrefix = "tag:github.com,2008:Grit::Commit/"
    private static let maximumAtomBytes = 2_097_152

    public static func extract(_ data: Data, owner: String, repository: String) throws -> String {
        guard !data.isEmpty, data.count <= maximumAtomBytes else {
            throw AndroidHubMirrorManifestFailure.unavailable
        }
        // The public feed is UTF-8: refuse NUL bytes and any non-UTF-8
        // encoding up front so an encoded DTD can never slip past the
        // declaration scan below. XMLParser also aborts on every DTD
        // declaration kind independently of this byte-level check.
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else {
            throw AndroidHubMirrorManifestFailure.unavailable
        }
        var lowered = [UInt8](data)
        for index in lowered.indices where (65...90).contains(lowered[index]) { lowered[index] += 32 }
        guard !containsSequence(lowered, Array("<!doctype".utf8)),
              !containsSequence(lowered, Array("<!entity".utf8)) else {
            throw AndroidHubMirrorManifestFailure.unavailable
        }
        let collector = AtomCommitCollector()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = collector
        guard parser.parse(), !collector.sawDTDDeclaration, collector.rootIsFeed,
              let entryID = collector.firstEntryID?.trimmingCharacters(in: .whitespacesAndNewlines),
              let entryLink = collector.firstEntryLink,
              entryID.hasPrefix(commitTagPrefix) else {
            throw AndroidHubMirrorManifestFailure.unavailable
        }
        let sha = String(entryID.dropFirst(commitTagPrefix.count))
        guard AndroidHubMirrorTransport.isCanonicalCommit(sha),
              entryLink == "https://github.com/\(owner)/\(repository)/commit/\(sha)" else {
            throw AndroidHubMirrorManifestFailure.unavailable
        }
        return sha
    }

    private static func containsSequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        var start = 0
        while start <= haystack.count - needle.count {
            var offset = 0
            while offset < needle.count, haystack[start + offset] == needle[offset] { offset += 1 }
            if offset == needle.count { return true }
            start += 1
        }
        return false
    }

    /// Minimal Atom delegate: root identity, the FIRST entry's id and link,
    /// and nothing else. Later entries can never override the first.
    private final class AtomCommitCollector: NSObject, XMLParserDelegate {
        var rootIsFeed = false
        var firstEntryID: String?
        var firstEntryLink: String?
        /// Set by any DTD declaration callback. Whatever the document
        /// encoding, XMLParser decodes before reporting these, so a DTD is
        /// refused here even if it evaded the raw byte scan.
        private(set) var sawDTDDeclaration = false
        private var depth = 0
        private var inFirstEntry = false
        private var sawFirstEntry = false
        private var capturingID = false
        private var idText = ""

        private func rejectDTD(_ parser: XMLParser) {
            sawDTDDeclaration = true
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) {
            rejectDTD(parser)
        }

        func parser(_ parser: XMLParser, foundAttributeDeclarationWithName attributeName: String,
                    forElement elementName: String, type: String?, defaultValue: String?) {
            rejectDTD(parser)
        }

        func parser(_ parser: XMLParser, foundNotationDeclarationWithName name: String,
                    publicID: String?, systemID: String?) {
            rejectDTD(parser)
        }

        func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String,
                    publicID: String?, systemID: String?, notationName: String?) {
            rejectDTD(parser)
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            rejectDTD(parser)
        }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                    publicID: String?, systemID: String?) {
            rejectDTD(parser)
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            let elementDepth = depth + 1
            if elementDepth == 1 { rootIsFeed = elementName == "feed" }
            if elementDepth == 2, elementName == "entry", !sawFirstEntry {
                sawFirstEntry = true
                inFirstEntry = true
            }
            if inFirstEntry, elementDepth == 3 {
                if elementName == "id", firstEntryID == nil {
                    capturingID = true
                    idText = ""
                } else if elementName == "link", firstEntryLink == nil {
                    firstEntryLink = attributeDict["href"]
                }
            }
            depth = elementDepth
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capturingID { idText += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if capturingID, depth == 3, elementName == "id" {
                firstEntryID = idText
                capturingID = false
            }
            if depth == 2, elementName == "entry" { inFirstEntry = false }
            depth -= 1
        }
    }
}
