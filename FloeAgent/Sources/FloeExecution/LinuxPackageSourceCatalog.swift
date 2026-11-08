// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

/// The same catalog is bundled with the App and copied into new ARM64 images.
/// Listing a preset is not a configuration change or authority to install.
public struct LinuxPackageSourceCatalog: Codable, Sendable {
    public struct AptPreset: Codable, Sendable, Identifiable, Equatable {
        public let id: String
        public let nameEN: String
        public let nameZH: String
        public let uri: String
        public let suites: [String]
        public let components: [String]
        public let securityURI: String
        public let securitySuite: String
        public let signedBy: String
        public var displayName: String { FloeL10n.isChinese ? nameZH : nameEN }
    }
    public struct PythonPreset: Codable, Sendable, Identifiable, Equatable {
        public let id: String
        public let nameEN: String
        public let nameZH: String
        public let indexURL: String
        public var displayName: String { FloeL10n.isChinese ? nameZH : nameEN }
    }
    public let schemaVersion: Int
    public let distribution: String
    public let suite: String
    public let apt: [AptPreset]
    public let python: [PythonPreset]

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32 * 1024 else { throw invalidCatalog() }
        let value = try JSONDecoder().decode(Self.self, from: data)
        func https(_ text: String) -> Bool {
            guard let url = URLComponents(string: text) else { return false }
            return url.scheme == "https" && url.host?.isEmpty == false
                && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
                && !text.contains(where: { $0.isWhitespace || $0.isNewline })
        }
        guard value.schemaVersion == 1, value.distribution == "debian", value.suite == "trixie",
              value.apt.count == 2, Set(value.apt.map(\.id)) == ["official", "tuna"],
              value.python.count == 2, Set(value.python.map(\.id)) == ["official", "tuna"],
              value.apt.allSatisfy({ preset in
                  https(preset.uri) && preset.suites == ["trixie", "trixie-updates"]
                    && preset.components == ["main"]
                    && preset.securityURI == "https://security.debian.org/debian-security"
                    && preset.securitySuite == "trixie-security"
                    && preset.signedBy == "/usr/share/keyrings/debian-archive-keyring.gpg"
              }),
              value.python.allSatisfy({ https($0.indexURL) && $0.indexURL.hasSuffix("/simple/") })
        else { throw invalidCatalog() }
        return value
    }

    private static let packaged: Result<Self, Error> = Result {
        guard let url = Bundle.module.url(forResource: "LinuxPackageSources", withExtension: "json") else {
            throw invalidCatalog()
        }
        return try decode(Data(contentsOf: url))
    }

    public static func bundled() throws -> Self { try packaged.get() }

    static func invalidCatalog() -> FloeError {
        .invalidConfiguration(FloeL10n.isChinese ? "软件源预设暂不可用。" : "Package source presets are unavailable.")
    }

    /// Discovery text derives endpoint values from the same catalog as the
    /// image and UI. It describes choices, never silently changes a repo.
    public static var modelInstructions: String {
        guard let catalog = try? bundled() else { return "" }
        let apt = catalog.apt.map { "\($0.id)=\($0.uri)" }.joined(separator: "; ")
        let python = catalog.python.map { "\($0.id)=\($0.indexURL)" }.joined(separator: "; ")
        return " Package source presets: Debian [\(apt)] and Python [\(python)]. Existing environments retain system APT sources unless the user explicitly selects a preset in Settings → Execution → Environments → Debian source. Python · PyPI uses its saved single index; custom sources are preserved. New images carry /usr/share/floe/package-sources.json; older frozen images may not. This is separate from VM image download mirrors. Never merge PyPI extra indexes, add trusted-host, disable TLS/signatures or switch sources to hide a package/version/integrity error."
    }
}
