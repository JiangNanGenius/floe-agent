#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeSkills
@testable import FloeApp

/// Offline contract tests for the anonymous immutable transport of the
/// trusted public curated Skill Hub: identity/route selection, immutable URL
/// construction, the strict Atom first-entry commit resolution and the
/// credential-free request shape. No network, no App build and no package
/// verification is exercised here; the live read is covered by the lane's
/// bounded probe and by Main's real install rerun.
@Suite("FloeApp.SkillHubPublicTransport")
struct SkillHubPublicTransportTests {
    private let trustedCommit = "0123456789abcdef0123456789abcdef01234567"
    private let otherCommit = "fedcba9876543210fedcba9876543210fedcba98"
    private let owner = "JiangNanGenius"
    private let repository = "floe-skill-hub"

    private func commitURL(_ commit: String, repository: String? = nil) -> String {
        "https://github.com/\(owner)/\(repository ?? self.repository)/commit/\(commit)"
    }

    private func atomFeed(
        entries: [(id: String, link: String?)],
        feedID: String = "tag:github.com,2008:/JiangNanGenius/floe-skill-hub/commits/main"
    ) -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xml:lang="en-US">
        <id>\(feedID)</id>
        <title>Recent Commits to floe-skill-hub:main</title>
        """
        for entry in entries {
            xml += "\n<entry>\n<id>\(entry.id)</id>\n"
            if let link = entry.link {
                xml += "<link type=\"text/html\" rel=\"alternate\" href=\"\(link)\"/>\n"
            }
            xml += "<title>fixture commit</title>\n</entry>"
        }
        xml += "\n</feed>"
        return Data(xml.utf8)
    }

    // MARK: - Route selection

    @Test func trustedRouteOnlyCoversTheExactAnonymousHub() {
        #expect(SkillHubPublicTransport.isPublicHubRoute(
            owner: owner, repository: repository, ref: "main", usesConnectorCredential: false))
        #expect(SkillHubPublicTransport.isPublicHubRoute(
            owner: owner, repository: repository, ref: trustedCommit, usesConnectorCredential: false))
        // A connector credential keeps the original API behavior.
        #expect(!SkillHubPublicTransport.isPublicHubRoute(
            owner: owner, repository: repository, ref: "main", usesConnectorCredential: true))
        #expect(!SkillHubPublicTransport.isPublicHubRoute(
            owner: owner, repository: repository, ref: trustedCommit, usesConnectorCredential: true))
        // Other repositories, other owners and every other mutable ref keep
        // the original API behavior.
        #expect(!SkillHubPublicTransport.isPublicHubRoute(
            owner: owner, repository: "floe-agent", ref: "main", usesConnectorCredential: false))
        #expect(!SkillHubPublicTransport.isPublicHubRoute(
            owner: "someone-else", repository: repository, ref: "main", usesConnectorCredential: false))
        #expect(!SkillHubPublicTransport.isPublicHubRoute(
            owner: "jiangnangenius", repository: repository, ref: "main", usesConnectorCredential: false))
        #expect(!SkillHubPublicTransport.isPublicHubRoute(
            owner: owner, repository: repository, ref: "release", usesConnectorCredential: false))
        #expect(!SkillHubPublicTransport.isPublicHubRoute(
            owner: owner, repository: repository, ref: "v1.0.0", usesConnectorCredential: false))
        #expect(!SkillHubPublicTransport.isPublicHubRoute(
            owner: owner, repository: repository, ref: String(repeating: "A", count: 40),
            usesConnectorCredential: false))
    }

    @Test func selectedPublicRouteRefusesInvalidPinnedRequestsInsteadOfFallingBack() {
        // A selected official anonymous route never reads mutable branch
        // bytes for a file path.
        if case .rejected = SkillHubPublicTransport.action(
            owner: owner, repository: repository, ref: "main", path: "catalog.json",
            usesConnectorCredential: false) {
        } else {
            Issue.record("a mutable ref with a file path must be rejected, not resolved through any fallback")
        }
        for path in ["../catalog.json", "a/../../b", "", "/catalog.json", "a%2Fb", "a?ref=main", "a b"] {
            if case .rejected = SkillHubPublicTransport.action(
                owner: owner, repository: repository, ref: trustedCommit, path: path,
                usesConnectorCredential: false) {
            } else {
                Issue.record("unsafe pinned path must be rejected without fallback: \(path)")
            }
        }
    }

    @Test func selectedPublicRouteYieldsOnlyImmutableActions() throws {
        struct Commit: Decodable { let sha: String }
        if case .atomFeed(let url) = SkillHubPublicTransport.action(
            owner: owner, repository: repository, ref: "main", path: nil,
            usesConnectorCredential: false) {
            #expect(url.absoluteString == "https://github.com/JiangNanGenius/floe-skill-hub/commits/main.atom")
        } else {
            Issue.record("`main` resolution must use the Atom commit feed")
        }

        if case .localCommitResolution(let data) = SkillHubPublicTransport.action(
            owner: owner, repository: repository, ref: trustedCommit, path: nil,
            usesConnectorCredential: false) {
            #expect(try JSONDecoder().decode(Commit.self, from: data).sha == trustedCommit)
        } else {
            Issue.record("an already-pinned commit must resolve locally without the network")
        }

        if case .pinnedFile(let url) = SkillHubPublicTransport.action(
            owner: owner, repository: repository, ref: trustedCommit, path: "catalog.json",
            usesConnectorCredential: false) {
            #expect(url.absoluteString
                == "https://raw.githubusercontent.com/JiangNanGenius/floe-skill-hub/\(trustedCommit)/catalog.json")
        } else {
            Issue.record("a pinned file must use the immutable raw endpoint")
        }
    }

    @Test func unselectedRequestsKeepTheLegacyBehavior() {
        #expect(SkillHubPublicTransport.action(
            owner: owner, repository: "floe-agent", ref: "main", path: "catalog.json",
            usesConnectorCredential: false) == nil)
        #expect(SkillHubPublicTransport.action(
            owner: owner, repository: repository, ref: "main", path: nil,
            usesConnectorCredential: true) == nil)
        #expect(SkillHubPublicTransport.action(
            owner: owner, repository: repository, ref: "release", path: "catalog.json",
            usesConnectorCredential: false) == nil)
        #expect(SkillHubPublicTransport.action(
            owner: owner, repository: repository, ref: "v1.0.0", path: nil,
            usesConnectorCredential: false) == nil)
        #expect(SkillHubPublicTransport.action(
            owner: "someone-else", repository: repository, ref: trustedCommit, path: "catalog.json",
            usesConnectorCredential: false) == nil)
    }

    // MARK: - Endpoints

    @Test func atomEndpointIsTheExactRepositoryCommitFeed() throws {
        let url = try #require(SkillHubPublicTransport.mainAtomURL(owner: owner, repository: repository))
        #expect(url.absoluteString == "https://github.com/JiangNanGenius/floe-skill-hub/commits/main.atom")
        #expect(url.scheme == "https")
        #expect(url.host == "github.com")
        #expect(url.query == nil)
        #expect(SkillHubPublicTransport.mainAtomURL(owner: owner, repository: "floe-agent") == nil)
        #expect(SkillHubPublicTransport.mainAtomURL(owner: "someone-else", repository: repository) == nil)
    }

    // MARK: - Pinned resolution and immutable file URLs

    @Test func pinnedCommitResolvesAsTheExistingCommitJSONWithoutNetwork() throws {
        struct Commit: Decodable { let sha: String }
        let data = try #require(SkillHubPublicTransport.localCommitResolutionData(ref: trustedCommit))
        #expect(try JSONDecoder().decode(Commit.self, from: data).sha == trustedCommit)
        #expect(SkillHubPublicTransport.localCommitResolutionData(ref: "main") == nil)
        #expect(SkillHubPublicTransport.localCommitResolutionData(ref: "HEAD") == nil)
        #expect(SkillHubPublicTransport.localCommitResolutionData(ref: String(repeating: "A", count: 40)) == nil)
        #expect(SkillHubPublicTransport.localCommitResolutionData(ref: String(trustedCommit.dropLast())) == nil)
        #expect(SkillHubPublicTransport.localCommitResolutionData(ref: trustedCommit + "0") == nil)
        #expect(SkillHubPublicTransport.localCommitResolutionData(ref: String(repeating: "g", count: 40)) == nil)
        #expect(SkillHubPublicTransport.localCommitResolutionData(ref: "") == nil)
    }

    @Test func rawURLCarriesTheExactPinnedCommitAndFile() throws {
        let catalog = try #require(SkillHubPublicTransport.rawFileURL(
            owner: owner, repository: repository, commit: trustedCommit, path: "catalog.json"))
        #expect(catalog.absoluteString
            == "https://raw.githubusercontent.com/JiangNanGenius/floe-skill-hub/\(trustedCommit)/catalog.json")
        #expect(catalog.scheme == "https")
        #expect(catalog.host == "raw.githubusercontent.com")
        #expect(catalog.query == nil)

        let zip = try #require(SkillHubPublicTransport.rawFileURL(
            owner: owner, repository: repository, commit: trustedCommit,
            path: "packages/doc-coauthoring/1.0.0/doc-coauthoring.zip"))
        #expect(zip.absoluteString.hasSuffix(
            "/\(trustedCommit)/packages/doc-coauthoring/1.0.0/doc-coauthoring.zip"))

        // Version strings carrying `+` stay one encoded path segment.
        let engine = try #require(SkillHubPublicTransport.rawFileURL(
            owner: owner, repository: repository, commit: trustedCommit,
            path: "engines/impeccable/dist/impeccable-0.1.17+floe.1.1.1/riscv64gc-unknown-linux-musl/floe-impeccable"))
        #expect(engine.absoluteString.contains("impeccable-0.1.17%2Bfloe.1.1.1"))
        #expect(!engine.absoluteString.contains("+"))
    }

    @Test func rawURLRejectsTraversalUnsafeBytesAndMutableRefs() {
        let rejectedPaths = [
            "", "/catalog.json", "../catalog.json", "a/../../b", "./catalog.json", "a/./b",
            "a//b", "a/", "a\\b", "a?ref=main", "a#fragment", "a%2Fb", "a b", "目录.json",
        ]
        for path in rejectedPaths {
            #expect(SkillHubPublicTransport.rawFileURL(
                owner: owner, repository: repository, commit: trustedCommit, path: path) == nil,
                "unsafe path must be rejected: \(path)")
        }
        // A mutable branch, a non-canonical ref, and any other repository
        // never produce a raw URL — there is no mutable `main` file fallback.
        #expect(SkillHubPublicTransport.rawFileURL(
            owner: owner, repository: repository, commit: "main", path: "catalog.json") == nil)
        #expect(SkillHubPublicTransport.rawFileURL(
            owner: owner, repository: repository, commit: String(repeating: "A", count: 40),
            path: "catalog.json") == nil)
        #expect(SkillHubPublicTransport.rawFileURL(
            owner: owner, repository: "floe-agent", commit: trustedCommit, path: "catalog.json") == nil)
        #expect(SkillHubPublicTransport.rawFileURL(
            owner: "someone-else", repository: repository, commit: trustedCommit,
            path: "catalog.json") == nil)
    }

    @Test func publicRequestsNeverCarryACredential() throws {
        let url = try #require(SkillHubPublicTransport.mainAtomURL(owner: owner, repository: repository))
        let atom = SkillHubPublicTransport.publicRequest(url: url, accept: "application/atom+xml")
        #expect(atom.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(atom.value(forHTTPHeaderField: "User-Agent") == "FloeAgent")
        #expect(atom.value(forHTTPHeaderField: "Accept") == "application/atom+xml")
        #expect(atom.timeoutInterval == 30)

        let raw = SkillHubPublicTransport.publicRequest(url: url, accept: nil)
        #expect(raw.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(raw.value(forHTTPHeaderField: "Accept") == nil)
    }

    // MARK: - Atom first-entry resolution

    @Test func atomFirstEntryResolvesTheImmutableCommit() throws {
        let data = atomFeed(entries: [
            ("tag:github.com,2008:Grit::Commit/\(trustedCommit)", commitURL(trustedCommit)),
            ("tag:github.com,2008:Grit::Commit/\(otherCommit)", commitURL(otherCommit)),
        ])
        let sha = try SkillHubPublicTransport.commitSHA(
            fromAtom: data, owner: owner, repository: repository)
        #expect(sha == trustedCommit)
    }

    @Test func feedLevelIdentityIsNeverAcceptedAsACommit() {
        let data = atomFeed(entries: [], feedID: "tag:github.com,2008:Grit::Commit/\(trustedCommit)")
        #expect(throws: (any Error).self) {
            try SkillHubPublicTransport.commitSHA(fromAtom: data, owner: owner, repository: repository)
        }
    }

    @Test func atomRequiresOneCompleteFirstEntry() {
        let link = commitURL(trustedCommit)
        let fixtures = [
            atomFeed(entries: []),
            atomFeed(entries: [("", link)]),
            atomFeed(entries: [("tag:github.com,2008:Grit::Commit/\(trustedCommit)", nil)]),
        ]
        for data in fixtures {
            #expect(throws: (any Error).self) {
                try SkillHubPublicTransport.commitSHA(fromAtom: data, owner: owner, repository: repository)
            }
        }
    }

    @Test func atomNeverScansPastTheFirstEntry() throws {
        // The first entry is authoritative even when a later entry names a
        // different (still valid) commit.
        let data = atomFeed(entries: [
            ("tag:github.com,2008:Grit::Commit/\(otherCommit)", commitURL(otherCommit)),
            ("tag:github.com,2008:Grit::Commit/\(trustedCommit)", commitURL(trustedCommit)),
        ])
        let sha = try SkillHubPublicTransport.commitSHA(fromAtom: data, owner: owner, repository: repository)
        #expect(sha == otherCommit)
        // An invalid first entry is never skipped in favour of a later one.
        let badFirst = atomFeed(entries: [
            ("not-a-commit", commitURL(trustedCommit)),
            ("tag:github.com,2008:Grit::Commit/\(trustedCommit)", commitURL(trustedCommit)),
        ])
        #expect(throws: (any Error).self) {
            try SkillHubPublicTransport.commitSHA(fromAtom: badFirst, owner: owner, repository: repository)
        }
    }

    @Test func atomEntryIdentityMustMatchTheTrustedRepositoryAndCommit() {
        let fixtures = [
            // The link names a different repository.
            atomFeed(entries: [
                ("tag:github.com,2008:Grit::Commit/\(trustedCommit)",
                 commitURL(trustedCommit, repository: "floe-agent")),
            ]),
            // The link names a different owner.
            atomFeed(entries: [
                ("tag:github.com,2008:Grit::Commit/\(trustedCommit)",
                 "https://github.com/someone-else/floe-skill-hub/commit/\(trustedCommit)"),
            ]),
            // The link's commit disagrees with the entry id.
            atomFeed(entries: [
                ("tag:github.com,2008:Grit::Commit/\(trustedCommit)", commitURL(otherCommit)),
            ]),
            // A non-commit link.
            atomFeed(entries: [
                ("tag:github.com,2008:Grit::Commit/\(trustedCommit)",
                 "https://github.com/JiangNanGenius/floe-skill-hub"),
            ]),
        ]
        for data in fixtures {
            #expect(throws: (any Error).self) {
                try SkillHubPublicTransport.commitSHA(fromAtom: data, owner: owner, repository: repository)
            }
        }
    }

    @Test func atomEntryShaMustBeCanonical() {
        let invalidIDs = [
            "tag:github.com,2008:Grit::Commit/\(trustedCommit.uppercased())",
            "tag:github.com,2008:Grit::Commit/\(String(trustedCommit.dropLast()))",
            "tag:github.com,2008:Grit::Commit/\(trustedCommit)0",
            "tag:github.com,2008:Grit::Commit/\(String(repeating: "g", count: 40))",
            "tag:github.com,2008:/JiangNanGenius/floe-skill-hub/commits/main",
            "https://github.com/JiangNanGenius/floe-skill-hub/commit/\(trustedCommit)",
        ]
        for id in invalidIDs {
            let data = atomFeed(entries: [(id, commitURL(trustedCommit))])
            #expect(throws: (any Error).self) {
                try SkillHubPublicTransport.commitSHA(fromAtom: data, owner: owner, repository: repository)
            }
        }
    }

    @Test func atomRootMustBeAFeed() {
        let rss = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><item><id>tag:github.com,2008:Grit::Commit/\(trustedCommit)</id>\
        <link href="\(commitURL(trustedCommit))"/></item></channel></rss>
        """.utf8)
        #expect(throws: (any Error).self) {
            try SkillHubPublicTransport.commitSHA(fromAtom: rss, owner: owner, repository: repository)
        }
    }

    // MARK: - Entity and size hardening

    @Test func atomExternalEntityDeclarationsAreRejected() {
        let bodies = [
            "<!DOCTYPE feed [<!ENTITY xxe SYSTEM \"file:///etc/passwd\">]>",
            "<!doctype feed [<!ENTITY xxe SYSTEM \"https://example.com/x\">]>",
        ]
        for declaration in bodies {
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            \(declaration)
            <feed xmlns="http://www.w3.org/2005/Atom">
            <entry><id>tag:github.com,2008:Grit::Commit/\(trustedCommit)</id>
            <link href="\(commitURL(trustedCommit))"/></entry></feed>
            """
            #expect(throws: (any Error).self) {
                try SkillHubPublicTransport.commitSHA(
                    fromAtom: Data(xml.utf8), owner: owner, repository: repository)
            }
        }
    }

    @Test func atomRejectsEncodedEntityPayloadsAndNonUTF8Input() {
        let xml16 = """
        <?xml version="1.0" encoding="UTF-16"?>
        <!DOCTYPE feed [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
        <feed xmlns="http://www.w3.org/2005/Atom"><entry><id>tag:github.com,2008:Grit::Commit/\(trustedCommit)</id>\
        <link href="\(commitURL(trustedCommit))"/></entry></feed>
        """
        let xml32 = xml16.replacingOccurrences(of: "encoding=\"UTF-16\"", with: "encoding=\"UTF-32\"")
        for (xml, encodings) in [
            (xml16, [String.Encoding.utf16, .utf16LittleEndian, .utf16BigEndian]),
            (xml32, [String.Encoding.utf32, .utf32LittleEndian, .utf32BigEndian]),
        ] {
            for encoding in encodings {
                guard let data = xml.data(using: encoding) else {
                    Issue.record("fixture encoding unavailable: \(encoding)")
                    continue
                }
                // An encoded DTD must be refused before XMLParser could
                // decode it; the raw ASCII scan alone must not be the only
                // barrier.
                #expect(throws: (any Error).self) {
                    try SkillHubPublicTransport.commitSHA(fromAtom: data, owner: owner, repository: repository)
                }
            }
        }
        // The public feed contract is plain UTF-8, so even a well-formed
        // UTF-16 feed is refused rather than parsed through an encoding path.
        let cleanFeed = atomFeed(entries: [
            ("tag:github.com,2008:Grit::Commit/\(trustedCommit)", commitURL(trustedCommit)),
        ])
        if let utf16 = String(data: cleanFeed, encoding: .utf8)?.data(using: .utf16) {
            #expect(throws: (any Error).self) {
                try SkillHubPublicTransport.commitSHA(fromAtom: utf16, owner: owner, repository: repository)
            }
        } else {
            Issue.record("UTF-16 fixture could not be produced")
        }
        // NUL bytes are never valid for this feed.
        var withNUL = atomFeed(entries: [
            ("tag:github.com,2008:Grit::Commit/\(trustedCommit)", commitURL(trustedCommit)),
        ])
        withNUL.insert(0, at: withNUL.startIndex)
        #expect(throws: (any Error).self) {
            try SkillHubPublicTransport.commitSHA(fromAtom: withNUL, owner: owner, repository: repository)
        }
    }

    @Test func atomFeedBoundIsEnforcedBeforeParsing() {
        let limit = SkillHubTransportBudget.maximumBytes(
            owner: CuratedSkillHub.owner, repository: CuratedSkillHub.repository, path: nil)
        let oversize = Data(repeating: 0x20, count: limit + 1)
        #expect(throws: (any Error).self) {
            try SkillHubPublicTransport.commitSHA(fromAtom: oversize, owner: owner, repository: repository)
        }
        #expect(throws: (any Error).self) {
            try SkillHubPublicTransport.commitSHA(fromAtom: Data(), owner: owner, repository: repository)
        }
    }
}
#endif
