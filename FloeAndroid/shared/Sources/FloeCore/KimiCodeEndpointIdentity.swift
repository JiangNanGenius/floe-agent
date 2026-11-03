// SPDX-License-Identifier: MPL-2.0
import Foundation

// Endpoint identity extracted unchanged from ProviderProfile.swift at
// upstream commit 10fc0083c0f8e341ec97ec517c20cfa4e45d7d09.
public enum KimiCodeEndpointIdentity {
    public static let apiHosts: Set<String> = ["api.kimi.com"]
    /// The only accepted base path variants (normalized, lowercase, no
    /// trailing slash). The bare host or any other path is unsupported.
    public static let basePathVariants: Set<String> = ["/coding", "/coding/v1"]

    public static func matches(_ provider: ProviderProfile) -> Bool {
        apiRoot(for: provider.baseURL) != nil
    }

    /// The verified API root — always `https://api.kimi.com[:port]/coding/v1`
    /// for a supported base — or nil when host/scheme/path/query/fragment is
    /// not one of the evidenced route variants.
    public static func apiRoot(for provider: ProviderProfile) -> URL? {
        apiRoot(for: provider.baseURL)
    }

    public static func apiRoot(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              apiHosts.contains(host),
              url.query == nil,
              url.fragment == nil else { return nil }
        var path = url.path.lowercased()
        while path.hasSuffix("/") && path != "/" { path = String(path.dropLast()) }
        if path == "/" { path = "" }
        guard basePathVariants.contains(path) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = url.port
        components.path = path.hasSuffix("/v1") ? path : path + "/v1"
        return components.url
    }
}
