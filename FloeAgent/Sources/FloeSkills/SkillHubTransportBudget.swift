import Foundation

/// Limits for the existing GitHub transport. A new signed Hub layout does
/// not broaden the budget of unrelated repository content.
public enum SkillHubTransportBudget {
    public static func maximumBytes(owner: String, repository: String, path: String?) -> Int {
        guard let path else { return 2_097_152 }
        if path.hasPrefix("skill-hub/packages/") { return 8_388_608 }
        guard owner == "JiangNanGenius", repository == "floe-skill-hub",
              !path.hasPrefix("/"), !path.contains("\\"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else { return 2_097_152 }
        if path == "catalog.json" || path == "android/catalog.json" { return 4_194_304 }
        if (path.hasPrefix("packages/") || path.hasPrefix("android/packages/")), path.hasSuffix(".zip") {
            return 8_388_608
        }
        return 2_097_152
    }
}
