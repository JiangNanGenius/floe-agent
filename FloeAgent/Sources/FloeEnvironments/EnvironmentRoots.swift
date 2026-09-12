import Foundation
import FloeCore

/// Filesystem layout for the container substrate. Everything lives under the
/// app's Application Support directory; nothing here is user-visible except
/// through `floe-env` and Settings.
public struct EnvironmentRoots: Sendable {
    public static let shared = EnvironmentRoots()

    public let rootURL: URL

    public init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let base = (try? FloeArtifactStore.root())
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("FloeAgent", isDirectory: true)
            self.rootURL = base.appendingPathComponent("Environments", isDirectory: true)
        }
    }

    public var containersURL: URL { rootURL.appendingPathComponent("Containers", isDirectory: true) }
    public var sharedURL: URL { rootURL.appendingPathComponent("Shared", isDirectory: true) }
    public var templatesURL: URL { rootURL.appendingPathComponent("Templates", isDirectory: true) }
    public var casURL: URL { rootURL.appendingPathComponent("Store", isDirectory: true) }
    public var trashURL: URL { rootURL.appendingPathComponent(".trash", isDirectory: true) }
    public var registryURL: URL { rootURL.appendingPathComponent("containers.json") }

    /// Base slices are versioned by app build. The app injects the bundled
    /// slice directory (or nil when the app ships without one).
    public func baseSliceURL(build: String) -> URL {
        rootURL.appendingPathComponent("Base", isDirectory: true)
            .appendingPathComponent(build, isDirectory: true)
    }

    public func containerURL(id: String) -> URL {
        containersURL.appendingPathComponent(id, isDirectory: true)
    }

    public func layerURL(id: String, kind: ContainerKind) -> URL {
        switch kind {
        case .session, .project:
            return containerURL(id: id)
        case .template:
            return templatesURL.appendingPathComponent(id, isDirectory: true)
        case .shared:
            return sharedURL
        }
    }

    @discardableResult
    public func prepare() throws -> URL {
        let fileManager = FileManager.default
        for url in [rootURL, containersURL, sharedURL, templatesURL, casURL, trashURL] {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        excludeFromBackup(rootURL)
        excludeFromBackup(casURL)
        excludeFromBackup(sharedURL)
        return rootURL
    }

    private func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    /// Standard container filesystem layout (FHS-like).
    public static let subdirectories = [
        "usr/bin", "usr/lib", "usr/lib/floe-python/site-packages", "usr/lib/floe-wasm",
        "usr/lib/node_modules", "usr/local/bin", "etc/apt/preferences.d",
        "etc/apt/trusted.gpg.d", "etc/apt/sources.list.d", "etc/profile.d",
        "var/lib/dpkg/info", "var/lib/apt/lists", "var/cache/apt/archives",
        "var/npm", "opt/pnpm-store", "opt/floe", "home", "tmp"
    ]

    public func materializeContainerLayout(at url: URL) throws {
        let fileManager = FileManager.default
        for subdirectory in Self.subdirectories {
            try fileManager.createDirectory(
                at: url.appendingPathComponent(subdirectory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let profile = """
        # Floe container profile
        export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        export HOME="/home/floe"
        export TMPDIR="/tmp"
        export LANG="en_US.UTF-8"
        """
        try? Data(profile.utf8).write(
            to: url.appendingPathComponent("etc/profile.d/00-floe.sh"),
            options: .atomic
        )
    }
}
