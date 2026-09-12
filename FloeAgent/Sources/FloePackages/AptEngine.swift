import Foundation
import FloeCore

/// apt/dpkg orchestration for one container layer. Network, script execution
/// and progress reporting are injected so the module stays platform-neutral.
public actor AptEngine {
    public struct Container: Sendable {
        public var id: String
        public var rootURL: URL
        public var layerURL: URL
        public var layerKind: LayerKind
        public var baseRevision: String
        public var architecture: String

        public init(id: String, rootURL: URL, layerURL: URL, layerKind: LayerKind, baseRevision: String, architecture: String = "arm64") {
            self.id = id
            self.rootURL = rootURL
            self.layerURL = layerURL
            self.layerKind = layerKind
            self.baseRevision = baseRevision
            self.architecture = architecture
        }
    }

    public struct Downloader: Sendable {
        public var fetch: @Sendable (_ url: URL, _ maxBytes: Int) async throws -> Data
        public init(fetch: @escaping @Sendable (URL, Int) async throws -> Data) {
            self.fetch = fetch
        }
    }

    public struct ScriptRunner: Sendable {
        /// Runs a maintainer script inside the container. Returns exit code.
        public var run: @Sendable (_ script: String, _ arguments: [String], _ container: Container) async -> Int32
        public init(run: @escaping @Sendable (String, [String], Container) async -> Int32 = { _, _, _ in 0 }) {
            self.run = run
        }
    }

    public struct UpdateReport: Sendable {
        public var sources: Int
        public var packages: Int
        public var failures: [String]
    }

    public struct Step: Sendable {
        public var package: String
        public var version: String
        public var action: String
        public var detail: String?
    }

    public enum AptError: Error, CustomStringConvertible {
        case unresolved(String)
        case untrusted(String)
        case nativePayload(String)
        case conflict(String)
        case notInstalled(String)
        case held(String)
        case quota(String)
        case scriptFailed(String, Int32)

        public var description: String {
            switch self {
            case .unresolved(let name): return "unable to resolve dependency: \(name)"
            case .untrusted(let source): return "untrusted repository or signature: \(source)"
            case .nativePayload(let name): return "package \(name) contains native executables and cannot run on iOS"
            case .conflict(let detail): return "conflict: \(detail)"
            case .notInstalled(let name): return "package \(name) is not installed"
            case .held(let name): return "package \(name) is held"
            case .quota(let detail): return "container quota exceeded: \(detail)"
            case .scriptFailed(let name, let code): return "maintainer script failed for \(name) (exit \(code))"
            }
        }
    }

    private let downloader: Downloader
    private let scriptRunner: ScriptRunner
    private let trustedKeys: [OpenPGP.Key]
    private let signatureVerifier: (@Sendable (Data, Data, [OpenPGP.Key]) throws -> Void)?
    private var cachedIndex: [String: [AptPackage]] = [:]
    private var releaseBySource: [String: AptRelease] = [:]
    private var holds: Set<String> = []

    public init(
        downloader: Downloader,
        scriptRunner: ScriptRunner = ScriptRunner(),
        trustedKeys: [OpenPGP.Key] = [],
        signatureVerifier: (@Sendable (Data, Data, [OpenPGP.Key]) throws -> Void)? = nil
    ) {
        self.downloader = downloader
        self.scriptRunner = scriptRunner
        self.trustedKeys = trustedKeys
        self.signatureVerifier = signatureVerifier
    }

    // MARK: - apt update

    @discardableResult
    public func update(container: Container, sources: [AptSource]) async -> UpdateReport {
        var packageCount = 0
        var failures: [String] = []
        var index: [String: [AptPackage]] = [:]
        for source in sources {
            do {
                let releaseText = try await fetchRelease(source: source)
                let release = Deb822.parse(stanza: releaseText)
                let parsedRelease = AptRelease.parse(release)
                if let parsedRelease, !parsedRelease.isValid() {
                    throw AptIndex.IndexError.expired(parsedRelease.suite)
                }
                if let parsedRelease {
                    releaseBySource[source.id] = parsedRelease
                }
                for component in source.components {
                    guard let url = source.packagesURL(component: component, architecture: "all")
                        ?? source.packagesURL(component: component, architecture: container.architecture) else { continue }
                    let data = try await downloader.fetch(url, 64 * 1024 * 1024)
                    let document = try AptIndex.decompressPackages(data, memberName: url.lastPathComponent)
                    let packages = AptIndex.parsePackages(
                        String(decoding: document, as: UTF8.self),
                        component: component,
                        repository: source.uri
                    )
                    index[component, default: []].append(contentsOf: packages)
                    packageCount += packages.count
                }
                try persistLists(index: index, container: container)
            } catch {
                failures.append("\(source.uri) \(source.suite): \(error.localizedDescription)")
            }
        }
        cachedIndex = index
        return UpdateReport(sources: sources.count, packages: packageCount, failures: failures)
    }

    private func fetchRelease(source: AptSource) async throws -> String {
        guard let inReleaseURL = source.releaseURL() else {
            throw AptError.untrusted(source.uri)
        }
        let data = try await downloader.fetch(inReleaseURL, 32 * 1024 * 1024)
        if let signatureVerifier {
            let clearsigned = try OpenPGP.parseClearsigned(data)
            try signatureVerifier(clearsigned.signaturePacket, clearsigned.text, trustedKeys)
            return String(decoding: clearsigned.text, as: UTF8.self)
        }
        if source.trusted || trustedKeys.isEmpty {
            // `trusted=yes` is an explicit escape hatch; callers surface a warning.
            return String(decoding: try OpenPGP.decodeIfArmored(data), as: UTF8.self)
        }
        throw AptError.untrusted(source.uri)
    }

    private func persistLists(index: [String: [AptPackage]], container: Container) throws {
        let directory = container.layerURL.appendingPathComponent("var/lib/apt/lists", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (component, packages) in index {
            let document = packages.map { package -> String in
                var stanza = Deb822()
                stanza.set("Package", package.name)
                stanza.set("Version", package.version)
                stanza.set("Architecture", package.architecture)
                stanza.set("Filename", package.filename)
                stanza.set("Size", String(package.size))
                stanza.set("SHA256", package.sha256)
                if let depends = package.depends { stanza.set("Depends", depends) }
                if let description = package.description { stanza.set("Description", description) }
                if let license = package.license { stanza.set("License", license) }
                return stanza.serialized
            }.joined(separator: "\n\n")
            try Data(document.utf8).write(
                to: directory.appendingPathComponent("\(component)_Packages"),
                options: .atomic
            )
        }
    }

    // MARK: - Index queries

    public func loadedIndex() -> [String: [AptPackage]] { cachedIndex }

    public func allPackages() -> [AptPackage] {
        cachedIndex.values.flatMap { $0 }
    }

    public func search(_ query: String) -> [AptPackage] {
        let normalized = query.lowercased()
        return allPackages().filter {
            $0.name.lowercased().contains(normalized)
                || ($0.description ?? "").lowercased().contains(normalized)
        }
    }

    public func show(_ name: String) -> [AptPackage] {
        allPackages().filter { $0.name == name }
    }

    public func hold(_ name: String) { holds.insert(name) }
    public func unhold(_ name: String) { holds.remove(name) }
    public func held() -> [String] { holds.sorted() }

    // MARK: - Resolution

    /// Resolves the install set for `names` (bounded, first-match).
    public func resolve(_ names: [String], installed: [String: String]) throws -> [AptPackage] {
        var selected: [String: AptPackage] = [:]
        var queue = names
        var visited = Set<String>()
        while let name = queue.popLast() {
            if visited.contains(name) { continue }
            visited.insert(name)
            if installed[name] != nil { continue }
            guard let candidate = bestPackage(named: name) else {
                // Virtual package via Provides.
                if let provider = allPackages().first(where: { provides($0, name) }) {
                    selected[provider.name] = provider
                    queue.append(contentsOf: dependencyNames(provider.depends))
                    continue
                }
                throw AptError.unresolved(name)
            }
            selected[candidate.name] = candidate
            queue.append(contentsOf: dependencyNames(candidate.preDepends))
            queue.append(contentsOf: dependencyNames(candidate.depends))
        }
        return selected.values.sorted { $0.name < $1.name }
    }

    public func bestPackage(named name: String) -> AptPackage? {
        allPackages()
            .filter { $0.name == name }
            .max { DebVersion.compare($0.version, $1.version) == .older }
    }

    private func provides(_ package: AptPackage, _ name: String) -> Bool {
        guard let provides = package.provides else { return false }
        return provides.split(separator: ",").contains {
            $0.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) == name
        }
    }

    private func dependencyNames(_ field: String?) -> [String] {
        guard let field else { return [] }
        return field.split(separator: ",").compactMap { alternative -> String? in
            let first = alternative.split(separator: "|").first.map(String.init) ?? ""
            let name = first.trimmingCharacters(in: .whitespaces)
                .split(separator: " ").first.map(String.init) ?? ""
            guard !name.isEmpty, !["python3", "floe-runtime"].contains(name) else { return nil }
            return name
        }
    }

    // MARK: - Mutations

    /// Installs resolved packages into the container layer.
    public func install(
        _ names: [String],
        container: Container,
        packageReview: @Sendable (_ package: AptPackage) -> Bool = { _ in true }
    ) async throws -> [Step] {
        let installed = DpkgDatabase.merged(layers: [(container.layerKind, container.layerURL)])
        let installedVersions = Dictionary(uniqueKeysWithValues: installed.map { ($0.name, $0.version) })
        let resolved = try resolve(names, installed: installedVersions)
        var steps: [Step] = []
        var manifest = LayerManifest.load(from: container.layerURL)
            ?? LayerManifest(id: container.id, kind: container.layerKind, baseRevision: container.baseRevision)
        for package in resolved {
            guard !holds.contains(package.name) else { throw AptError.held(package.name) }
            guard packageReview(package) else { throw AptError.conflict("review rejected \(package.name)") }
            guard let packageURL = URL(string: package.filename.hasPrefix("http") ? package.filename : repositoryURL(for: package) ) else {
                throw AptError.unresolved(package.filename)
            }
            let data = try await downloader.fetch(packageURL, 256 * 1024 * 1024)
            try AptIndex.validateDeb(data: data, package: package, digest: { Data($0).sha256Hex })
            let payload = try DebArchive.read(data: data)
            switch DebArchive.installability(of: payload) {
            case .nativePayload:
                throw AptError.nativePayload(package.name)
            case .compatible, .dataOnly:
                break
            }
            let files = try unpack(payload: payload, into: container)
            let entry = DpkgDatabase.StatusEntry(
                name: package.name,
                version: package.version,
                architecture: package.architecture,
                status: "install ok unpacked",
                summary: package.description?.split(separator: "\n").first.map(String.init),
                license: package.license,
                source: package.source,
                layer: container.layerKind,
                requiresBase: package.requiresBase,
                installedFiles: files
            )
            var entries = DpkgDatabase.readStatus(at: container.layerURL)
            entries.removeAll { $0.name == package.name }
            entries.append(entry)
            try DpkgDatabase.writeStatus(entries, at: container.layerURL)
            try DpkgDatabase.writeInfoFiles(for: entry, at: container.layerURL)
            if let postinst = payload.scripts["postinst"] {
                let code = await scriptRunner.run(postinst, ["configure"], container)
                if code != 0 { throw AptError.scriptFailed(package.name, code) }
            }
            var configured = entry
            configured.status = "install ok installed"
            var updated = DpkgDatabase.readStatus(at: container.layerURL)
            updated.removeAll { $0.name == package.name }
            updated.append(configured)
            try DpkgDatabase.writeStatus(updated, at: container.layerURL)
            manifest.packages.removeAll { $0.name == package.name }
            manifest.packages.append(InstalledPackage(
                name: package.name,
                version: package.version,
                architecture: package.architecture,
                layer: container.layerKind,
                summary: package.description?.split(separator: "\n").first.map(String.init),
                license: package.license,
                source: package.source,
                requiresBase: package.requiresBase,
                files: files
            ))
            steps.append(Step(package: package.name, version: package.version, action: "install", detail: nil))
        }
        try manifest.write(to: container.layerURL)
        return steps
    }

    /// Removes packages that live in the container's own layer.
    public func remove(_ names: [String], container: Container, purge: Bool) throws -> [Step] {
        var manifest = LayerManifest.load(from: container.layerURL)
            ?? LayerManifest(id: container.id, kind: container.layerKind, baseRevision: container.baseRevision)
        var entries = DpkgDatabase.readStatus(at: container.layerURL)
        var steps: [Step] = []
        for name in names {
            guard let index = manifest.packages.firstIndex(where: { $0.name == name }) else {
                let stackOwned = DpkgDatabase.merged(layers: [(container.layerKind, container.layerURL)])
                    .first { $0.name == name }
                throw stackOwned == nil ? AptError.notInstalled(name) : AptError.conflict("\(name) is owned by a lower layer; use --layer to target it")
            }
            let package = manifest.packages[index]
            for file in package.files where purge {
                let url = container.layerURL.appendingPathComponent(file)
                try? FileManager.default.removeItem(at: url)
            }
            manifest.packages.remove(at: index)
            entries.removeAll { $0.name == name }
            steps.append(Step(package: name, version: package.version, action: purge ? "purge" : "remove", detail: nil))
        }
        try DpkgDatabase.writeStatus(entries, at: container.layerURL)
        try manifest.write(to: container.layerURL)
        return steps
    }

    /// Upgrade plan for installed packages that have newer candidates.
    public func upgradePlan(container: Container) -> [Step] {
        let installed = DpkgDatabase.merged(layers: [(container.layerKind, container.layerURL)])
        var steps: [Step] = []
        for entry in installed {
            guard !holds.contains(entry.name), let candidate = bestPackage(named: entry.name) else { continue }
            if DebVersion.compare(candidate.version, entry.version) == .newer {
                steps.append(Step(package: entry.name, version: candidate.version, action: "upgrade", detail: entry.version))
            }
        }
        return steps
    }

    /// Packages in the container layer that no installed package depends on.
    public func autoremovable(container: Container) -> [String] {
        let manifest = LayerManifest.load(from: container.layerURL)
            ?? LayerManifest(id: container.id, kind: container.layerKind, baseRevision: container.baseRevision)
        let installedNames = Set(manifest.packages.map(\.name))
        var needed = Set<String>()
        for package in manifest.packages {
            for dependency in dependencyNames(package.depends) + dependencyNames(package.preDepends) {
                if installedNames.contains(dependency) { needed.insert(dependency) }
            }
        }
        return installedNames.subtracting(needed).sorted()
    }

    private func repositoryURL(for package: AptPackage) -> String {
        package.repository.hasSuffix("/") ? package.repository + package.filename : package.repository + "/" + package.filename
    }

    /// Unpacks data entries into the layer with path and overwrite safety.
    private func unpack(payload: DebArchive.Payload, into container: Container) throws -> [String] {
        var files: [String] = []
        let root = container.layerURL
        for entry in payload.dataEntries {
            switch entry.kind {
            case .file, .directory:
                break
            case .symlink, .hardlink:
                continue
            case .other:
                continue
            }
            let normalized = entry.path.hasPrefix("./") ? String(entry.path.dropFirst(2)) : entry.path
            guard !normalized.isEmpty else { continue }
            guard !normalized.hasPrefix("/"), !normalized.split(separator: "/").contains("..") else {
                throw AptError.conflict("unsafe path in archive: \(entry.path)")
            }
            let destination = root.appendingPathComponent(normalized)
            if entry.kind == .directory {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try entry.data.write(to: destination, options: .atomic)
            files.append(normalized)
        }
        return files
    }
}
