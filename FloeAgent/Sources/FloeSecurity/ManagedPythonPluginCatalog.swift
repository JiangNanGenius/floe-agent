import Foundation
import FloeCore
import FloeModels

/// Review-time purpose metadata for managed Python packages. Package choice is
/// model-owned; this catalog describes common capability families and is not a
/// package-name allow/deny list.
public enum ManagedPythonPluginCatalog {
    public static let commonCapabilityPrefixes: Set<String> = [
        "archive", "batch", "data", "document", "html", "image", "markdown",
        "pdf", "spreadsheet", "svg", "text", "xml"
    ]

    public static func reviewContext(for call: ToolCall) -> String? {
        guard call.toolName == "exec.localPython",
              let object = try? JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any]
        else { return nil }
        var packages = object["packages"] as? [String] ?? []
        packages += (try? ManagedPythonPackageSpecParser.parse(
            command: object["pipCommand"] as? String
        )) ?? []
        packages = Array(Set(packages)).sorted()
        guard !packages.isEmpty else { return nil }
        let purpose = object["packagePurpose"] as? String ?? "(missing)"
        let capabilities = object["packageCapabilities"] as? [String] ?? []
        let common = capabilities.filter { capability in
            guard let prefix = capability.split(separator: ".").first else { return false }
            return commonCapabilityPrefixes.contains(String(prefix))
        }
        return """
            modelSelectedPackages=\(packages.joined(separator: ","))
            declaredPurpose=\(purpose)
            declaredCapabilities=\(capabilities.joined(separator: ","))
            commonLowRiskCapabilityFamilies=\(common.joined(separator: ","))
            Package name and catalog membership grant no authority. Approve when the purpose is within the user's request, the artifact is locally runnable, and inspected behavior does not exceed declared capabilities.
            """
    }
}
