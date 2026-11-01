import Foundation

/// Build identity shared by the host, the embedded test bundle and the tunnel.
///
/// Every role must report the same marketing version and build number. The
/// package verifier checks this against the plists instead of trusting the
/// build system.
public enum BridgeBuild {
    public static let marketingVersion = "1.0.0"
    public static let buildNumber = "18"

    public static let canonicalHostBundleIdentifier = "org.floeagent.iosbridge"

    /// A re-signed app may have a developer-owned identifier. Resolve the
    /// matching extension from the installed host rather than the build's
    /// original identifier; otherwise an otherwise valid re-sign cannot start
    /// its own packet tunnel. The embedded test runs in the host process.
    public static var hostBundleIdentifier: String {
        resolveHostBundleIdentifier(
            mainBundleIdentifier: Bundle.main.bundleIdentifier,
            isTunnelExtension: Bundle.main.bundleURL.pathExtension == "appex"
        ) ?? canonicalHostBundleIdentifier
    }

    public static var tunnelBundleIdentifier: String { hostBundleIdentifier + ".tunnel" }
    public static var coreBundleIdentifier: String { hostBundleIdentifier + ".core" }

    public static func resolveHostBundleIdentifier(
        mainBundleIdentifier: String?, isTunnelExtension: Bool
    ) -> String? {
        guard let identifier = mainBundleIdentifier, !identifier.isEmpty else { return nil }
        guard isTunnelExtension else { return identifier }
        let suffix = ".tunnel"
        guard identifier.hasSuffix(suffix), identifier.count > suffix.count else { return nil }
        return String(identifier.dropLast(suffix.count))
    }

    public static let testBundleName = "BridgeTests.xctest"
    public static let testBundlePath = "PlugIns/\(testBundleName)"
    public static let tunnelAppexPath = "PlugIns/BridgeTunnel.appex"

    /// Legacy prototype entrances stay disabled in every product-content build.
    public static let prototypeDiagnostics = false

    public static func bundleInfo(for bundle: Bundle = .main) -> [String: String] {
        var info: [String: String] = [
            "bundleIdentifier": bundle.bundleIdentifier ?? "<missing>",
            "marketingVersion": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "<missing>",
            "buildNumber": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "<missing>",
            "executable": bundle.executablePath ?? "<missing>",
            "bundlePath": bundle.bundlePath,
        ]
        info["expectedMarketingVersion"] = marketingVersion
        info["expectedBuildNumber"] = buildNumber
        return info
    }
}
