import Foundation

/// Credential boundaries for subscription endpoints. This is connection
/// identity, not an editable billing switch or a fallback policy.
public enum ProviderBillingEndpoint: String, Sendable, CaseIterable {
    case volcengineAgentPlan = "volcengine-agent-plan"
    case alibabaTokenPlan = "alibaba-token-plan"

    public static func resolve(_ url: URL) -> Self? {
        guard url.scheme?.lowercased() == "https",
              url.port == nil || url.port == 443 else { return nil }
        let host = (url.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if host == "ark.cn-beijing.volces.com", path == "api/plan/v3" {
            return .volcengineAgentPlan
        }
        if host == "token-plan.cn-beijing.maas.aliyuncs.com", path == "compatible-mode/v1" {
            return .alibabaTokenPlan
        }
        return nil
    }
}
