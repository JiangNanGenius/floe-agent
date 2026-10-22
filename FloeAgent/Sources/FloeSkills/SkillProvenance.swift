// FloeSkills — truthful skill origin classification.
//
// The hub badge must state how a skill really arrived on this device. Names,
// enabled state and model-written metadata are display data, never evidence.
// Classification reads only the persisted install/creator bindings that the
// reviewed write paths own: `source_url`, `rewritten_digest`,
// `rewrite_model_id` and the signature-verified official catalog digest.
// An official ID alone proves nothing: a row is `.official` only when its
// bytes or its reviewed transaction bind it to the trusted bundled package
// or the signed Official Skill Hub. Anything else that cannot be proven is
// `.unknown` — never mislabeled.

import Foundation

/// Compact origin badge shown on installed and Discover skill rows.
public enum SkillOrigin: String, Codable, Equatable, Sendable, CaseIterable {
    /// Bundled with the app binary, or installed through a signature-verified
    /// Official Skill Hub transaction whose content binds to the trusted feed.
    case official
    /// Authored on this device through the reviewed creator pipeline (the
    /// on-device creator UI or the `skill.create` agent tool).
    case internalCreated = "internal"
    /// Imported or downloaded from an external source (Skill Finder HTTPS
    /// envelope, GitHub/community package, local folder import).
    case external
    /// Legacy or inconsistent row whose creation cannot be proven.
    case unknown

    /// Shared localization catalog key for the compact badge label.
    public var badgeKey: String { "skills.origin." + rawValue }
}

public enum SkillOriginResolver {
    /// Exact scheme written by `SkillsCenter.createSkill` for on-device
    /// creation (UI authoring and the `skill.create` tool share this path).
    public static let creatorURLScheme = "floe-creator"

    /// Classify one persisted skill row.
    ///
    /// - Parameter verifiedCatalogContentDigest: canonical content digest of
    ///   the current signature-verified Official Skill Hub catalog entry for
    ///   this skill ID, when one was fetched successfully. Pass `nil` when
    ///   the catalog is unknown; a digest match then cannot be claimed.
    public static func origin(
        id: String,
        sourceURL: String?,
        rewrittenDigest: String,
        rewriteModelID: String?,
        verifiedCatalogContentDigest: String? = nil
    ) -> SkillOrigin {
        let url = sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. App-bundled preset seeded under the reserved builtin binding.
        //    Hub-official presets must additionally match the signed bundled
        //    package bytes shipped inside this app build.
        if let url, url == BundledDomainSkills.sourceURL(for: id),
           BundledDomainSkills.all.contains(where: { $0.id == id }) {
            if OfficialSkillHub.skillIDs.contains(id) {
                if let bundled = BundledDomainSkills.officialPackageDigests[id],
                   digestEquals(bundled, rewrittenDigest) { return .official }
            } else {
                return .official
            }
        }

        // 2. Official Skill Hub: either the installed bytes equal the current
        //    signature-verified catalog entry, or the row carries the exact
        //    immutable commit written by the reviewed official upgrade
        //    transaction (`github-reviewed-<commit>` bound to the same commit
        //    embedded in the official catalog URL).
        if OfficialSkillHub.skillIDs.contains(id) {
            if let verifiedCatalogContentDigest,
               digestEquals(verifiedCatalogContentDigest, rewrittenDigest) { return .official }
            if let commit = officialHubCommit(in: url),
               rewriteModelID == "github-reviewed-\(commit)" { return .official }
        }

        // 3. Created on this device: the creator pipeline writes the exact
        //    `floe-creator://local/<id>` binding and later instruction edits
        //    preserve it, so the tag survives updates and restarts.
        if let url, url == "\(creatorURLScheme)://local/\(id)" { return .internalCreated }

        // 4. External import: Skill Finder and GitHub/community upgrades persist
        //    an https source URL; folder imports persist the folder binding.
        if let scheme = scheme(of: url),
           scheme == "https" || scheme == "floe-folder" { return .external }

        // 5. Anything else (nil, legacy or inconsistent bindings) is unknown.
        return .unknown
    }

    /// Commit of the canonical official catalog blob URL written by the
    /// reviewed official upgrade transaction, or `nil` when the URL does not
    /// have that exact trusted form. Mirrors the source binding accepted by
    /// `OfficialSkillHub.acceptsBundledUpgrade`.
    static func officialHubCommit(in sourceURL: String?) -> String? {
        guard let sourceURL, let url = URL(string: sourceURL), url.scheme == "https",
              url.host == "github.com", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.port == nil else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 6, parts[0] == OfficialSkillHub.owner,
              parts[1] == OfficialSkillHub.repository, parts[2] == "blob",
              parts[3].count == 40, parts[3].allSatisfy(\.isHexDigit),
              parts[4] == "skill-hub", parts[5] == "catalog.json" else { return nil }
        return parts[3].lowercased()
    }

    private static func scheme(of url: String?) -> String? {
        guard let url, !url.isEmpty, let parsed = URL(string: url),
              let scheme = parsed.scheme else { return nil }
        return scheme.lowercased()
    }

    private static func digestEquals(_ trusted: String, _ installed: String) -> Bool {
        installed.caseInsensitiveCompare(trusted) == .orderedSame
    }
}
