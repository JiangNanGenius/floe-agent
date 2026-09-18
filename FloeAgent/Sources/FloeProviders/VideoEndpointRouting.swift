import Foundation

/// Model-family endpoint routing for the three native video adapters.
///
/// Official contracts verified 2026-09-18:
/// - Google Veo: `POST {root}/v1beta/models/{model}:predictLongRunning`,
///   `GET {root}/v1beta/{operationName}`; the Interactions (Omni) API lives on
///   the configured `/v1` root instead.
/// - Alibaba DashScope (Wan 3.0): `POST {root}/api/v1/services/aigc/video-generation/video-synthesis`,
///   `GET {root}/api/v1/tasks/{task_id}` on the provider host root, never under
///   the OpenAI-compatible `/compatible-mode/v1` prefix used for chat.
/// - Volcengine Ark already uses its own `{base}/api/v3/contents/generations/tasks`
///   contract and is routed from the provider base URL unchanged.
///
/// A user-configured custom base URL keeps its host, port and path prefix; only
/// the trailing API version component is normalized when the official contract
/// requires a different one.
public enum VideoEndpointRouting {
    /// Veo is the only Google family that needs `v1beta`; Interactions/Omni
    /// stays on the configured version root.
    public static func googleUsesBetaVersion(modelRemoteID: String) -> Bool {
        !modelRemoteID.lowercased().hasPrefix("gemini-omni-")
    }

    /// Returns the Google root for the given model family. Only a trailing
    /// `/v1` or `/v1beta` component is rewritten, so a custom host or proxy
    /// path prefix survives.
    public static func googleRoot(baseURL: URL, modelRemoteID: String) -> URL {
        guard googleUsesBetaVersion(modelRemoteID: modelRemoteID) else { return baseURL }
        let path = baseURL.path
        if path.hasSuffix("/v1beta") { return baseURL }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        if path.hasSuffix("/v1") {
            let prefix = String(path.dropLast("/v1".count))
            components?.path = (prefix.isEmpty ? "" : prefix) + "/v1beta"
        } else if path.isEmpty || path == "/" {
            components?.path = "/v1beta"
        } else {
            components?.path = path + "/v1beta"
        }
        return components?.url ?? baseURL
    }

    /// Returns the DashScope native API root (`.../api/v1`) for a provider base
    /// URL. The public default points at `/compatible-mode/v1`; workspace
    /// subdomains such as `{WorkspaceId}.cn-beijing.maas.aliyuncs.com` carry no
    /// path. Any other custom host/path is preserved verbatim so a private
    /// gateway keeps working.
    public static func dashScopeAPIRoot(baseURL: URL) -> URL {
        let path = baseURL.path
        if path.hasSuffix("/api/v1") { return baseURL }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        if path.hasSuffix("/compatible-mode/v1") {
            let prefix = String(path.dropLast("/compatible-mode/v1".count))
            components?.path = (prefix.isEmpty ? "" : prefix) + "/api/v1"
            return components?.url ?? baseURL
        }
        if let host = baseURL.host?.lowercased(), host.hasSuffix("aliyuncs.com") {
            components?.path = "/api/v1"
            return components?.url ?? baseURL
        }
        return baseURL
    }
}
