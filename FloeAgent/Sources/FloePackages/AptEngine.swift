import FloeEnvironments
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
        public init(run: @escaping @Sendable (String, [String], Container) async -> Int32 = { _, _, _ in 126 }) {
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
    private var indexes: [String: [String: [AptPackage]]] = [:]
    private var mutating = Set<String>()
    private var releaseBySource: [String: AptRelease] = [:]

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
                guard let parsedRelease = AptRelease.parse(release) else { throw AptError.untrusted(source.uri) }
                if !parsedRelease.isValid() {
                    throw AptIndex.IndexError.expired(parsedRelease.suite)
                }
                releaseBySource[source.id] = parsedRelease
                for component in source.components {
                    guard let url = source.packagesURL(component: component, architecture: "all")
                        ?? source.packagesURL(component: component, architecture: container.architecture) else { continue }
                    let data = try await downloader.fetch(url, 64 * 1024 * 1024)
                    guard let releaseRoot = source.releaseURL()?.deletingLastPathComponent().path else { throw AptError.untrusted(source.uri) }
                    let prefix = releaseRoot + "/"
                    guard url.path.hasPrefix(prefix) else { throw AptError.untrusted(source.uri) }
                    try AptIndex.validate(packagesData: data, relativePath: String(url.path.dropFirst(prefix.count)),
                        release: parsedRelease, digest: { FloeDigest.sha256Hex($0) })
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
        indexes[container.id] = index
        return UpdateReport(sources: sources.count, packages: packageCount, failures: failures)
    }

    private func fetchRelease(source: AptSource) async throws -> String {
        guard let inReleaseURL = source.releaseURL() else {
            throw AptError.untrusted(source.uri)
        }
        let data = try await downloader.fetch(inReleaseURL, 32 * 1024 * 1024)
        guard !trustedKeys.isEmpty else { throw AptError.untrusted(source.uri) }
        let clearsigned = try OpenPGP.parseClearsigned(data)
        if let signatureVerifier {
            try signatureVerifier(clearsigned.signaturePacket, clearsigned.text, trustedKeys)
        } else {
            try OpenPGP.verify(signaturePacketBody: clearsigned.signaturePacket, over: clearsigned.text, keys: trustedKeys)
        }
        return String(decoding: clearsigned.text, as: UTF8.self)
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

    public func loadedIndex(container: Container) -> [String: [AptPackage]] { indexes[container.id] ?? [:] }

    public func allPackages(container: Container) -> [AptPackage] {
        (indexes[container.id] ?? [:]).values.flatMap { $0 }
    }

    public func search(_ query: String, container: Container) -> [AptPackage] {
        let normalized = query.lowercased()
        return allPackages(container: container).filter {
            $0.name.lowercased().contains(normalized)
                || ($0.description ?? "").lowercased().contains(normalized)
        }
    }

    public func show(_ name: String, container: Container) -> [AptPackage] {
        allPackages(container: container).filter { $0.name == name }
    }

    public func hold(_ name: String, container: Container) throws {
        var names = try held(container: container); if !names.contains(name) { names.append(name) }
        try writeHolds(names, container: container)
    }
    public func unhold(_ name: String, container: Container) throws {
        try writeHolds(held(container: container).filter { $0 != name }, container: container)
    }
    public func held(container: Container) throws -> [String] {
        let url = container.layerURL.appendingPathComponent("var/lib/apt/floe-holds.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([String].self, from: Data(contentsOf: url)).sorted()
    }
    private func writeHolds(_ names: [String], container: Container) throws {
        let url = container.layerURL.appendingPathComponent("var/lib/apt/floe-holds.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(names.sorted()).write(to: url, options: .atomic)
    }

    // MARK: - Resolution

    /// Resolves the install set for `names` (bounded, first-match).
    public func resolve(_ names: [String], installed: [String: String], container: Container) throws -> [AptPackage] {
        try PackageDependencyResolver.resolve(names, available: allPackages(container: container), installed: installed, architecture: container.architecture)
    }

    public func bestPackage(named name: String, container: Container) -> AptPackage? {
        allPackages(container: container)
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
        guard mutating.insert(container.id).inserted else { throw AptError.conflict("another package transaction is active") }
        defer { mutating.remove(container.id) }
        try PackageTransaction.recover(root: container.layerURL)
        let installed = DpkgDatabase.readStatus(at: container.layerURL)
        let installedVersions = Dictionary(uniqueKeysWithValues: installed.filter(\.isInstalled).map { ($0.name, $0.version) })
        let resolved = try resolve(names, installed: installedVersions, container: container)
        guard !resolved.isEmpty else { return [] }
        var manifest = try LayerManifest.loadChecked(from: container.layerURL)
            ?? LayerManifest(id: container.id, kind: container.layerKind, baseRevision: container.baseRevision)
        var prepared: [(AptPackage, DebArchive.Payload, [String])] = []
        var paths = Set([LayerManifest.fileName, "var/lib/dpkg/status"])
        let owners = installed.reduce(into: [String: String]()) { result, package in
            for file in package.installedFiles { result[file] = package.name }
        }
        var claimed: [String: String] = [:]
        for package in resolved {
            try Task.checkCancellation()
            guard try !held(container: container).contains(package.name) else { throw AptError.held(package.name) }
            guard packageReview(package) else { throw AptError.conflict("review rejected \(package.name)") }
            _ = try PackageDependencyResolver.Requirement(package.name)
            if let base = package.requiresBase, base != container.baseRevision { throw AptError.conflict("\(package.name) requires base \(base)") }
            guard let packageURL = URL(string: package.filename.hasPrefix("https://") ? package.filename : repositoryURL(for: package)) else { throw AptError.unresolved(package.filename) }
            let data = try await downloader.fetch(packageURL, 256 * 1024 * 1024)
            try Task.checkCancellation()
            try AptIndex.validateDeb(data: data, package: package, digest: { FloeDigest.sha256Hex(Data($0)) })
            let payload = try DebArchive.read(data: data)
            guard payload.control["Package"] == package.name, payload.control["Version"] == package.version,
                  payload.control["Architecture"] == package.architecture else { throw AptError.conflict("downloaded package identity differs from signed index") }
            guard payload.scripts.isEmpty else { throw AptError.scriptFailed(package.name, 126) }
            guard !payload.controlEntries.contains(where: { ($0.path as NSString).lastPathComponent == "conffiles" && !$0.data.isEmpty }) else {
                throw AptError.conflict("conffiles migration is not supported by this package build")
            }
            if DebArchive.installability(of: payload) == .nativePayload { throw AptError.nativePayload(package.name) }
            var files: [String] = []
            for entry in payload.dataEntries {
                var path = entry.path.hasPrefix("./") ? String(entry.path.dropFirst(2)) : entry.path
                if entry.kind == .directory && (path.isEmpty || path == ".") { continue }
                if entry.kind == .directory { while path.hasSuffix("/") { path.removeLast() } }
                guard !path.hasPrefix(PackageTransaction.directoryName), !path.hasPrefix("var/lib/dpkg/"),
                      !path.hasPrefix("var/lib/apt/"), !path.hasPrefix("opt/floe/") else { throw AptError.conflict("package targets reserved state") }
                let destination = try PackageTransaction.location(path, root: container.layerURL)
                guard entry.kind == .file || entry.kind == .directory else { throw AptError.conflict("archive links and special files require a compatible package build") }
                guard entry.kind == .file else { continue }
                if let owner = owners[path], owner != package.name { throw AptError.conflict("\(path) belongs to \(owner)") }
                if let owner = claimed[path], owner != package.name { throw AptError.conflict("multiple packages claim \(path)") }
                if FileManager.default.fileExists(atPath: destination.path), owners[path] == nil { throw AptError.conflict("\(path) is an existing unowned file") }
                if let old = manifest.packages.first(where: { $0.name == package.name }), let digest = old.fileDigests?[path],
                   FileManager.default.fileExists(atPath: destination.path), FloeDigest.sha256Hex(try Data(contentsOf: destination)) != digest {
                    throw AptError.conflict("\(path) was modified locally; preserve or restore it before upgrading")
                }
                guard !files.contains(path) else { throw AptError.conflict("duplicate archive file \(path)") }
                claimed[path] = package.name; files.append(path); paths.insert(path)
            }
            for old in installed.first(where: { $0.name == package.name })?.installedFiles ?? [] {
                let url = try PackageTransaction.location(old, root: container.layerURL)
                if let digest = manifest.packages.first(where: { $0.name == package.name })?.fileDigests?[old],
                   FileManager.default.fileExists(atPath: url.path), FloeDigest.sha256Hex(try Data(contentsOf: url)) != digest {
                    throw AptError.conflict("\(old) was modified locally; upgrade was cancelled")
                }
                paths.insert(old)
            }
            paths.insert("var/lib/dpkg/info/\(package.name).list")
            paths.insert("var/lib/dpkg/info/\(package.name).md5sums")
            prepared.append((package, payload, files))
        }
        let transaction = try PackageTransaction(root: container.layerURL, paths: Array(paths))
        do {
            var entries = installed
            var steps: [Step] = []
            for (package, payload, files) in prepared {
                try Task.checkCancellation()
                for old in installed.first(where: { $0.name == package.name })?.installedFiles ?? [] where !files.contains(old) {
                    try transaction.remove(old)
                }
                var digests: [String: String] = [:]
                for entry in payload.dataEntries where entry.kind == .file {
                    let path = entry.path.hasPrefix("./") ? String(entry.path.dropFirst(2)) : entry.path
                    try transaction.write(entry.data, to: path, mode: Int(entry.mode))
                    digests[path] = FloeDigest.sha256Hex(entry.data)
                }
                let entry = DpkgDatabase.StatusEntry(name: package.name, version: package.version,
                    architecture: package.architecture, summary: package.description, license: package.license,
                    source: package.source, layer: container.layerKind, requiresBase: package.requiresBase, installedFiles: files)
                entries.removeAll { $0.name == package.name }; entries.append(entry)
                try DpkgDatabase.writeInfoFiles(for: entry, at: container.layerURL)
                manifest.packages.removeAll { $0.name == package.name }
                manifest.packages.append(InstalledPackage(name: package.name, version: package.version, architecture: package.architecture,
                    layer: container.layerKind, summary: package.description, license: package.license, source: package.source,
                    requiresBase: package.requiresBase, files: files, depends: package.depends, preDepends: package.preDepends, fileDigests: digests))
                steps.append(Step(package: package.name, version: package.version, action: installedVersions[package.name] == nil ? "install" : "upgrade", detail: nil))
            }
            try DpkgDatabase.writeStatus(entries, at: container.layerURL)
            try manifest.write(to: container.layerURL)
            try transaction.commit()
            return steps
        } catch {
            do { try PackageTransaction.recover(root: container.layerURL) }
            catch { throw AptError.conflict("package recovery failed; journal retained: \(error)") }
            throw error
        }
    }

    /// Removes owned payload files. Shared directories and unrelated files survive.
    public func remove(_ names: [String], container: Container, purge: Bool) throws -> [Step] {
        guard mutating.insert(container.id).inserted else { throw AptError.conflict("another package transaction is active") }
        defer { mutating.remove(container.id) }
        try PackageTransaction.recover(root: container.layerURL)
        guard var manifest = try LayerManifest.loadChecked(from: container.layerURL) else { throw AptError.notInstalled(names.first ?? "") }
        var entries = DpkgDatabase.readStatus(at: container.layerURL)
        let removing = Set(names)
        for package in manifest.packages where !removing.contains(package.name) {
            for group in try PackageDependencyResolver.groups(package.depends) + PackageDependencyResolver.groups(package.preDepends) {
                if group.contains(where: { removing.contains($0.name) }) && !group.contains(where: { dependency in
                    !removing.contains(dependency.name) && entries.contains { $0.name == dependency.name && dependency.accepts($0.version) }
                }) { throw AptError.conflict("\(package.name) still depends on a requested package") }
            }
        }
        var paths = Set([LayerManifest.fileName, "var/lib/dpkg/status"])
        var steps: [Step] = []
        for name in removing.sorted() {
            guard let package = manifest.packages.first(where: { $0.name == name }) else { throw AptError.notInstalled(name) }
            guard try !held(container: container).contains(name) else { throw AptError.held(name) }
            for file in package.files {
                guard !manifest.packages.contains(where: { $0.name != name && $0.files.contains(file) }) else { throw AptError.conflict("\(file) has another owner") }
                let url = try PackageTransaction.location(file, root: container.layerURL)
                if let digest = package.fileDigests?[file], FileManager.default.fileExists(atPath: url.path),
                   FloeDigest.sha256Hex(try Data(contentsOf: url)) != digest { throw AptError.conflict("\(file) was modified locally; removal was cancelled") }
                paths.insert(file)
            }
            paths.insert("var/lib/dpkg/info/\(name).list"); paths.insert("var/lib/dpkg/info/\(name).md5sums")
            steps.append(Step(package: name, version: package.version, action: purge ? "purge" : "remove", detail: nil))
        }
        let transaction = try PackageTransaction(root: container.layerURL, paths: Array(paths))
        do {
            for path in paths where path != LayerManifest.fileName && path != "var/lib/dpkg/status" { try transaction.remove(path) }
            manifest.packages.removeAll { removing.contains($0.name) }; entries.removeAll { removing.contains($0.name) }
            try DpkgDatabase.writeStatus(entries, at: container.layerURL); try manifest.write(to: container.layerURL)
            try transaction.commit(); return steps
        } catch {
            do { try PackageTransaction.recover(root: container.layerURL) }
            catch { throw AptError.conflict("package recovery failed; journal retained: \(error)") }
            throw error
        }
    }

    /// Upgrade plan for installed packages that have newer candidates.
    public func upgradePlan(container: Container) throws -> [Step] {
        let installed = DpkgDatabase.merged(layers: [(container.layerKind, container.layerURL)])
        var steps: [Step] = []
        for entry in installed {
            guard try !held(container: container).contains(entry.name), let candidate = bestPackage(named: entry.name, container: container) else { continue }
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

}
