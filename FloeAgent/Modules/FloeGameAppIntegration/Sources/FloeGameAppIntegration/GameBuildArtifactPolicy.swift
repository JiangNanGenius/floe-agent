// SPDX-License-Identifier: MPL-2.0
import Foundation

/// What a build route actually produces. The App must not present a source
/// archive or a native project as a signed installer.
public enum GameBuildArtifactKind: String, Codable, Equatable, Sendable {
    case sourceArchive
    case webBundle
    case nativeProject
    case nativeInstaller
    case narrativeWeb
    case unknown

    public var isPlayableInApp: Bool {
        switch self {
        case .webBundle, .narrativeWeb: return true
        case .sourceArchive, .nativeProject, .nativeInstaller, .unknown: return false
        }
    }

    public var isInstallablePackage: Bool { self == .nativeInstaller }

    public var requiresExternalToolOrCI: Bool {
        switch self {
        case .nativeProject, .nativeInstaller: return true
        case .sourceArchive, .webBundle, .narrativeWeb, .unknown: return false
        }
    }
}

/// A build route after the App has resolved its real catalog entry. `executed`
/// stays false until an actual artifact has been produced and verified.
public struct GameBuildOption: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let artifactName: String
    public let kind: GameBuildArtifactKind
    public let producer: String
    public let platform: String?
    public let playable: Bool
    public let executed: Bool

    public init(id: String, artifactName: String, kind: GameBuildArtifactKind,
                producer: String, platform: String?, playable: Bool, executed: Bool) {
        self.id = id
        self.artifactName = artifactName
        self.kind = kind
        self.producer = producer
        self.platform = platform
        self.playable = playable
        self.executed = executed
    }
}

/// Pure presentation policy. It consumes catalog metadata; it does not run a
/// build, dispatch CI, download a tool or claim that an artifact exists.
public enum GameBuildArtifactPolicy {
    public static func kind(routeID: String, artifactName: String,
                            kindHint: String?, platform: String?) -> GameBuildArtifactKind {
        let route = routeID.lowercased()
        let name = artifactName.lowercased()
        let hint = kindHint?.lowercased() ?? ""
        let platform = platform?.lowercased() ?? ""

        if hint == "sourcearchive" || name.contains("source.zip") || route.hasSuffix("-source") {
            return .sourceArchive
        }
        if hint == "nativeinstaller" || name.hasSuffix(".apk") || name.hasSuffix(".ipa")
            || name.hasSuffix(".exe") || name.hasSuffix(".dmg") || name.hasSuffix(".pkg")
            || name.hasSuffix(".msi") || name.hasSuffix(".appimage") {
            return .nativeInstaller
        }
        if hint == "nativeproject" || name.contains("xcodeproj") || name.contains("android-project") {
            return .nativeProject
        }
        if hint == "webbundle" || platform == "web" || name.contains("web.zip") || name.contains("webgl") {
            if ["ink", "twine", "wasm4", "tic80", "microstudio"].contains(where: { route.hasPrefix($0) }) {
                return .narrativeWeb
            }
            return .webBundle
        }
        return .unknown
    }

    /// Selectable outputs for the build sheet. Source is always present, but
    /// it is labelled separately from playable and installable outputs.
    public static func options(from routes: [GameBuildOption],
                               includeSource: Bool = true) -> [GameBuildOption] {
        var values = routes
        if !includeSource { values = values.filter { $0.kind != .sourceArchive } }
        return values.sorted {
            if $0.kind == $1.kind { return $0.id < $1.id }
            return rank($0.kind) < rank($1.kind)
        }
    }

    /// The default selection never silently chooses an installable package or
    /// a source archive when a playable Web route exists.
    public static func defaultSelection(from routes: [GameBuildOption]) -> GameBuildOption? {
        routes.first(where: { $0.kind == .webBundle || $0.kind == .narrativeWeb })
            ?? routes.first(where: { $0.kind == .nativeProject })
            ?? routes.first(where: { $0.kind == .nativeInstaller })
            ?? routes.first
    }

    /// A route's playable flag is metadata. A build result is only "ready"
    /// when every requested output returned verified bytes.
    public static func isReady(requested: [GameBuildOption],
                               verifiedArtifactNames: Set<String>) -> Bool {
        guard !requested.isEmpty else { return false }
        return requested.allSatisfy { verifiedArtifactNames.contains($0.artifactName) }
    }

    /// Development instrumentation must not be included silently in an
    /// ordinary exported game. The App consumes the instrumentation API's
    /// `requiresRebuild`/dormancy result and passes this explicit value.
    public static func exportDisclosure(developerInstrumentationInstalled: Bool,
                                        sourceBundleAttached: Bool) -> String? {
        guard developerInstrumentationInstalled else { return nil }
        if sourceBundleAttached {
            return "The exported game contains inert development hooks. The matching FloeDeveloper source bundle is attached."
        }
        return "Development hooks are installed but the matching source bundle is not attached. Review before distributing."
    }

    private static func rank(_ kind: GameBuildArtifactKind) -> Int {
        switch kind {
        case .webBundle, .narrativeWeb: return 0
        case .sourceArchive: return 1
        case .nativeProject: return 2
        case .nativeInstaller: return 3
        case .unknown: return 4
        }
    }
}
