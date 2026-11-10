import Foundation

/// Limits for the existing GitHub transport. A new signed Hub layout does
/// not broaden the budget of unrelated repository content.
public enum SkillHubTransportBudget {
    /// A capability projection does not relax generic GitHub URL budgets.
    public static func maximumBytes(owner: String, repository: String, ref: String, path: String?,
        verifiedPackage: CuratedSkillHub.PackageDownloadAuthorization?) throws -> Int {
        if let verifiedPackage {
            return try verifiedPackage.maximumBytes(owner: owner, repository: repository, ref: ref, path: path)
        }
        return maximumBytes(owner: owner, repository: repository, path: path)
    }
    public static func maximumBytes(owner: String, repository: String, path: String?) -> Int {
        guard let path else { return 2_097_152 }
        if path.hasPrefix("skill-hub/packages/") { return 8_388_608 }
        guard owner == "JiangNanGenius", repository == "floe-skill-hub",
              !path.hasPrefix("/"), !path.contains("\\"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else { return 2_097_152 }
        // The two fixed channel layouts share the feed bound. The expanded
        // full paths receive the same 4 MiB ceiling as the legacy projection;
        // no other repository path gains a larger budget.
        if path == CuratedSkillCatalogLayout.legacy.catalogPath(for: .ios)
            || path == CuratedSkillCatalogLayout.legacy.catalogPath(for: .android)
            || path == CuratedSkillCatalogLayout.full.catalogPath(for: .ios)
            || path == CuratedSkillCatalogLayout.full.catalogPath(for: .android)
            || path == CuratedSkillCatalogLayout.largeSourceV1.catalogPath(for: .ios)
            || path == CuratedSkillCatalogLayout.largeSourceV1.catalogPath(for: .android) {
            return 4_194_304
        }
        if (path.hasPrefix("packages/") || path.hasPrefix("android/packages/")), path.hasSuffix(".zip") {
            return 8_388_608
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 6, parts[0] == "engines", parts[2] == "dist",
           parts[4] == SkillRuntimeDependency.frozenTargetTriple {
            let prefix: String?
            switch (parts[1], parts[5]) {
            case ("impeccable", "floe-impeccable"): prefix = "impeccable-"
            case ("ortie", "floe-ortie"): prefix = "ortie-"
            default: prefix = nil
            }
            if let prefix, parts[3].hasPrefix(prefix) {
                let version = parts[3].dropFirst(prefix.count)
                let safeVersion = !version.isEmpty && version.utf8.allSatisfy {
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                        || $0 == 46 || $0 == 43 || $0 == 45
                }
                if safeVersion { return 16_777_216 }
            }
        }
        return 2_097_152
    }
}
