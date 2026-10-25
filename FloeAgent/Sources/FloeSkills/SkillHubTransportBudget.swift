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
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 6,
           parts[0] == "engines", parts[1] == "impeccable", parts[2] == "dist",
           parts[3].hasPrefix("impeccable-"),
           parts[4] == "riscv64gc-unknown-linux-musl", parts[5] == "floe-impeccable" {
            let version = parts[3].dropFirst("impeccable-".count)
            let safeVersion = !version.isEmpty && version.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 46 || $0 == 43 || $0 == 45
            }
            if safeVersion { return 16_777_216 }
        }
        return 2_097_152
    }
}
