import Foundation
import FloeModels

/// Review-time catalog metadata for pure-Python plugins. Catalog membership
/// supplies provenance and prior review history; it never bypasses the model
/// review or the installer's platform/native-code checks.
public enum ManagedPythonPluginCatalog {
    public static let trustedPackageNames: Set<String> = [
        "beautifulsoup4", "certifi", "click", "feedparser", "httpx", "idna",
        "markdown", "openpyxl", "pypdf", "requests", "rich", "sqlparse",
        "tomli", "urllib3"
    ]

    public static func reviewContext(for call: ToolCall) -> String? {
        guard call.toolName == "exec.localPython",
              let object = try? JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any],
              let packages = object["packages"] as? [String], !packages.isEmpty
        else { return nil }
        let entries = packages.map { spec -> String in
            let name = normalizedName(spec)
            let provenance = trustedPackageNames.contains(name)
                ? "listed in Floe plugin catalog; still requires review"
                : "outside Floe plugin catalog; require stronger scrutiny"
            return "- \(spec): \(provenance)"
        }
        return entries.joined(separator: "\n")
    }

    private static func normalizedName(_ spec: String) -> String {
        let base = spec.split(separator: "=", maxSplits: 1).first.map(String.init) ?? spec
        let withoutExtras = base.split(separator: "[", maxSplits: 1).first.map(String.init) ?? base
        return withoutExtras.lowercased().replacingOccurrences(of: "_", with: "-")
    }
}
