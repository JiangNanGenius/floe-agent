import FloeTools
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
            #if os(Android)
            // ANDROID MIRROR DELTA (FloeAndroid/shared, G03-R1): on Android a
            // non-nil root is validated with the SAME rules as
            // `makeTrusted(rootURL:)`; malformed input fails closed instead
            // of silently owning an unintended location. Apple keeps the
            // original assignment byte-equal.
            self.rootURL = URL(fileURLWithPath: Self.preconditionTrustedPath(rootURL), isDirectory: true)
            #else
            self.rootURL = rootURL
            #endif
        } else {
            #if os(Android)
            // ANDROID MIRROR DELTA (FloeAndroid/shared, G03-R1): Android
            // production requires an EXPLICIT trusted persistent root from
            // the composition (`makeTrusted(rootURL:)`). There is NO implicit
            // fallback — not to the global artifact store and never to a
            // temporary directory the OS can reap: environment records, layer
            // manifests and CAS blobs must survive under the root the trusted
            // host selected. Fail closed.
            preconditionFailure("FloeEnvironments on Android requires an explicit trusted persistent root; pass EnvironmentRoots.makeTrusted(rootURL:)")
            #else
            let base = (try? FloeArtifactStore.root())
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("FloeAgent", isDirectory: true)
            self.rootURL = base.appendingPathComponent("Environments", isDirectory: true)
            #endif
        }
    }

    /// Trusted-composition entry point: validates that `rootURL` is a
    /// well-formed absolute file URL naming a real directory location, then
    /// owns it as the environment root. Android production composition MUST
    /// use this (or the equally validated non-nil `init(rootURL:)`), never
    /// the default `init()`; a model envelope can never widen or select this
    /// root.
    public static func makeTrusted(rootURL: URL) throws -> EnvironmentRoots {
        guard let path = trustedPath(rootURL) else {
            throw FloeError.validationFailed("Environment root must be an absolute, normalized, app-private file URL")
        }
        return EnvironmentRoots(rootURL: URL(fileURLWithPath: path, isDirectory: true))
    }

    /// Shared validation: returns the standardized path of a well-formed
    /// absolute file URL, or nil. Used by the throwing `makeTrusted` and the
    /// Android fail-closed `init(rootURL:)`.
    private static func trustedPath(_ rootURL: URL) -> String? {
        guard rootURL.isFileURL else { return nil }
        let standardized = rootURL.standardizedFileURL
        let path = standardized.path
        guard !path.isEmpty, path.hasPrefix("/"), path != "/", path.utf8.count <= 4096 else { return nil }
        guard !path.unicodeScalars.contains(where: { $0 == "\u{0}" || CharacterSet.controlCharacters.contains($0) }) else { return nil }
        // Accept the common trailing-slash spelling exactly once; reject any
        // other non-normalized form (traversal, doubled slashes, dot dirs).
        if rootURL.path.hasSuffix("/") {
            guard rootURL.path == path + "/" else { return nil }
        } else {
            guard rootURL.path == path else { return nil }
        }
        return path
    }

    #if os(Android)
    /// Android only: trusted-path validation whose failure is a loud
    /// programmer error (the composition handed a malformed root). The
    /// throwing variant for recoverable call sites remains `makeTrusted`.
    private static func preconditionTrustedPath(_ rootURL: URL) -> String {
        guard let path = trustedPath(rootURL) else {
            preconditionFailure("EnvironmentRoots(rootURL:) on Android received a non-trusted root; use EnvironmentRoots.makeTrusted(rootURL:)")
        }
        return path
    }
    #endif

    public var containersURL: URL { rootURL.appendingPathComponent("Containers", isDirectory: true) }
    public var sharedURL: URL { rootURL.appendingPathComponent("Shared", isDirectory: true) }
    public var templatesURL: URL { rootURL.appendingPathComponent("Templates", isDirectory: true) }
    public var casURL: URL { rootURL.appendingPathComponent("Store", isDirectory: true) }
    public var trashURL: URL { rootURL.appendingPathComponent(".trash", isDirectory: true) }
    public var registryURL: URL { rootURL.appendingPathComponent("containers.json") }

    /// Base slices are versioned by runtime ABI compatibility, independently of app builds. The app injects the bundled
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
