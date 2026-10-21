import Foundation
import FloeCore
import FloeTools

/// One skill-hub model artifact entry (catalog schema v2 `models` section).
public struct ModelArtifact: Codable, Sendable, Hashable, Identifiable {
    public struct File: Codable, Sendable, Hashable {
        public var path: String
        public var url: String
        public var sha256: String
        public var sizeBytes: Int64?

        public init(path: String, url: String, sha256: String, sizeBytes: Int64? = nil) {
            self.path = path
            self.url = url
            self.sha256 = sha256
            self.sizeBytes = sizeBytes
        }
    }

    public var id: String
    public var version: String
    public var kind: String
    public var capability: String
    public var skillID: String?
    public var files: [File]
    public var minAppVersion: String?
    public var license: String?
    public var source: String?
    public var convertedBy: String?
    public var platforms: [String]?
    public var notes: String?
    public var status: String?

    public init(
        id: String,
        version: String,
        kind: String,
        capability: String,
        skillID: String? = nil,
        files: [File],
        minAppVersion: String? = nil,
        license: String? = nil,
        source: String? = nil,
        convertedBy: String? = nil,
        platforms: [String]? = nil,
        notes: String? = nil,
        status: String? = nil
    ) {
        self.id = id
        self.version = version
        self.kind = kind
        self.capability = capability
        self.skillID = skillID
        self.files = files
        self.minAppVersion = minAppVersion
        self.license = license
        self.source = source
        self.convertedBy = convertedBy
        self.platforms = platforms
        self.notes = notes
        self.status = status
    }

    /// Catalog presence alone does not make an artifact installable.
    public var isInstallable: Bool {
        status == "ready" && !files.isEmpty && !(license ?? "").isEmpty && files.allSatisfy {
            guard let url = URL(string: $0.url) else { return false }
            return url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
                && $0.sha256.count == 64 && $0.sha256.allSatisfy(\.isHexDigit)
                && ($0.sizeBytes ?? 0) > 0
        }
    }

    public var totalBytes: Int64 {
        files.reduce(0) { total, file in
            let size = max(0, file.sizeBytes ?? 0)
            let (sum, overflow) = total.addingReportingOverflow(size)
            return overflow ? Int64.max : sum
        }
    }
}

/// Parsed catalog plus the verification hook supplied by the app
/// (Ed25519 signature over the catalog bytes via the skill-hub trust root).
public struct ModelArtifactCatalog: Sendable {
    public var models: [ModelArtifact]
    public var catalogSHA256: String

    public init(models: [ModelArtifact], catalogSHA256: String) {
        self.models = models
        self.catalogSHA256 = catalogSHA256
    }

    public static func parse(
        catalogData: Data,
        signatureVerifier: @Sendable (Data) throws -> Void
    ) throws -> ModelArtifactCatalog {
        try signatureVerifier(catalogData)
        struct Envelope: Decodable {
            var models: [ModelArtifact]?
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: catalogData)
        return ModelArtifactCatalog(
            models: envelope.models ?? [],
            catalogSHA256: FloeDigest.sha256Hex(catalogData)
        )
    }

    public func models(capability: String) -> [ModelArtifact] {
        models.filter { $0.capability == capability }
    }

    public func model(id: String) -> ModelArtifact? {
        models.first { $0.id == id }
    }
}

public struct InstalledModel: Codable, Sendable, Hashable {
    public enum Scope: String, Codable, Sendable, CaseIterable {
        case session
        case project
        case shared
    }

    public var id: String
    public var version: String
    public var capability: String
    public var scope: Scope
    public var rootPath: String
    public var sha256: String
    public var license: String?
    public var installedAt: Date

    public init(
        id: String,
        version: String,
        capability: String,
        scope: Scope,
        rootPath: String,
        sha256: String,
        license: String? = nil,
        installedAt: Date = Date()
    ) {
        self.id = id
        self.version = version
        self.capability = capability
        self.scope = scope
        self.rootPath = rootPath
        self.sha256 = sha256
        self.license = license
        self.installedAt = installedAt
    }
}

/// Model artifact store. Downloads are explicit, verified against the signed
/// catalog and installed into the requested scope; `media.models` is the only
/// entry point (apt stays a package manager).
public actor ModelArtifactStore {
    public typealias Downloader = @Sendable (_ url: URL, _ maxBytes: Int64) async throws -> Data

    public struct Limits: Sendable {
        public var maximumFileBytes: Int64
        public var maximumTotalBytes: Int64

        public init(maximumFileBytes: Int64 = 512 * 1024 * 1024, maximumTotalBytes: Int64 = 4 * 1024 * 1024 * 1024) {
            self.maximumFileBytes = maximumFileBytes
            self.maximumTotalBytes = maximumTotalBytes
        }
    }

    private let rootURL: URL
    private let downloader: Downloader
    private let limits: Limits
    private let fileManager = FileManager.default
    private var mutationActive = false

    public init(rootURL: URL, downloader: @escaping Downloader, limits: Limits = Limits()) {
        self.rootURL = rootURL
        self.downloader = downloader
        self.limits = limits
    }

    private var manifestURL: URL { rootURL.appendingPathComponent("installed-models.json") }

    public func installed() -> [InstalledModel] {
        (try? installedChecked()) ?? []
    }

    private func installedChecked() throws -> [InstalledModel] {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return [] }
        let models = try decoder().decode([InstalledModel].self, from: Data(floeContentsOf: manifestURL))
        guard Set(models.map(\.id)).count == models.count else {
            throw FloeError.validationFailed("Duplicate installed model records")
        }
        return models.sorted { $0.id < $1.id }
    }

    public func installed(id: String) -> InstalledModel? {
        installed().first { $0.id == id }
    }

    /// Installs all files of one artifact. SHA-256 is verified file by file;
    /// failures leave no partial install behind.
    @discardableResult
    public func install(
        _ artifact: ModelArtifact,
        scope: InstalledModel.Scope,
        cancellation: CancellationToken?
    ) async throws -> InstalledModel {
        guard !mutationActive else { throw FloeError.validationFailed("Another model mutation is active") }
        mutationActive = true
        defer { mutationActive = false }
        guard artifact.isInstallable else {
            throw FloeError.validationFailed("model \(artifact.id) is not a verified ready artifact")
        }
        guard !artifact.version.contains("/"), Set(artifact.files.map(\.path)).count == artifact.files.count else {
            throw FloeError.validationFailed("Invalid model version or duplicate file path")
        }
        let existingModels = try installedChecked()
        let destination = try safePath("\(scope.rawValue)/\(artifact.id)/\(artifact.version)", beneath: rootURL)
        for file in artifact.files {
            _ = try safePath(file.path, beneath: destination)
            guard let size = file.sizeBytes, size <= limits.maximumFileBytes else {
                throw FloeError.validationFailed("Model file exceeds the download limit")
            }
        }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            var total: Int64 = 0
            for file in artifact.files {
                try cancellation?.throwIfCancelled()
                guard let url = URL(string: file.url) else {
                    throw FloeError.validationFailed("invalid model file URL: \(file.path)")
                }
                let data = try await downloader(url, limits.maximumFileBytes)
                try cancellation?.throwIfCancelled()
                guard Int64(data.count) <= limits.maximumFileBytes, Int64(data.count) == file.sizeBytes else {
                    throw FloeError.validationFailed("Model file size differs from the signed catalog")
                }
                guard Int64(data.count) <= limits.maximumTotalBytes - total else {
                    throw FloeError.validationFailed("Model exceeds the total download limit")
                }
                total += Int64(data.count)
                guard total <= limits.maximumTotalBytes else {
                    throw FloeError.validationFailed("model exceeds the \(limits.maximumTotalBytes)-byte limit")
                }
                let digest = FloeDigest.sha256Hex(data)
                guard digest.caseInsensitiveCompare(file.sha256) == .orderedSame else {
                    throw FloeError.validationFailed("sha256 mismatch for \(file.path)")
                }
                let target = try safePath(file.path, beneath: staging)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            }
            if artifact.kind == "coreml", ["video.interpolate", "video.superResolution"].contains(artifact.capability) {
                try validateEnhancementBundle(at: staging, id: artifact.id, version: artifact.version, capability: artifact.capability)
            }
            // Never replace a registered model until explicit removal has completed.
            guard !fileManager.fileExists(atPath: destination.path), !existingModels.contains(where: { $0.id == artifact.id }) else {
                throw FloeError.validationFailed("Model already installed; remove it before installing another version")
            }
            try cancellation?.throwIfCancelled()
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: staging, to: destination)
            var models = existingModels
            models.removeAll { $0.id == artifact.id }
            let record = InstalledModel(
                id: artifact.id,
                version: artifact.version,
                capability: artifact.capability,
                scope: scope,
                rootPath: destination.path,
                sha256: artifact.files.map(\.sha256).joined(separator: ":"),
                license: artifact.license
            )
            models.append(record)
            do { try persist(models) }
            catch {
                try? fileManager.moveItem(at: destination, to: staging)
                throw error
            }
            return record
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    /// Installs a locally produced, already-compiled model bundle (the
    /// development/qualification path). Every file is verified against the
    /// bundle manifest before it is copied, and the same `InstalledModel`
    /// records the catalog installer writes. This is deliberately separate
    /// from the tool-visible `media.models install` path, which stays
    /// catalog-only. Returns the existing record when the identical version
    /// is already installed.
    @discardableResult
    public func installLocalBundle(at bundleURL: URL, scope: InstalledModel.Scope) async throws -> InstalledModel {
        guard !mutationActive else { throw FloeError.validationFailed("Another model mutation is active") }
        mutationActive = true
        defer { mutationActive = false }
        let fileManager = FileManager.default
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(floeContentsOf: manifestURL) else {
            throw FloeError.validationFailed("model bundle has no manifest.json")
        }
        struct Manifest: Decodable {
            struct File: Decodable {
                var path: String
                var sha256: String
                var sizeBytes: Int64?
            }
            var id: String
            var version: String
            var capability: String
            var license: String?
            var files: [File]
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        let contractURL = bundleURL.appendingPathComponent("contract.json")
        if let contractData = try? Data(floeContentsOf: contractURL),
           let contract = try? JSONDecoder().decode(MediaModelContract.self, from: contractData) {
            guard contract.id == manifest.id, contract.version == manifest.version else {
                throw FloeError.validationFailed("model bundle manifest and contract disagree on id/version")
            }
        }
        for file in manifest.files {
            let source = try safePath(file.path, beneath: bundleURL)
            guard fileManager.fileExists(atPath: source.path) else {
                throw FloeError.validationFailed("model bundle is missing \(file.path)")
            }
            let digest = (try? FloeDigest.sha256Hex(ofFileAt: source)) ?? ""
            guard digest.caseInsensitiveCompare(file.sha256) == .orderedSame else {
                throw FloeError.validationFailed("sha256 mismatch for \(file.path)")
            }
            _ = try safePath(file.path, beneath: bundleURL)
        }
        try validateEnhancementBundle(at: bundleURL, id: manifest.id, version: manifest.version, capability: manifest.capability)
        if let existing = try installedChecked().first(where: { $0.id == manifest.id }) {
            if existing.version == manifest.version,
               URL(fileURLWithPath: existing.rootPath).standardizedFileURL ==
               (try safePath("\(scope.rawValue)/\(manifest.id)/\(manifest.version)", beneath: rootURL)).standardizedFileURL {
                try validateEnhancementBundle(at: URL(fileURLWithPath: existing.rootPath), id: manifest.id, version: manifest.version, capability: manifest.capability)
                let installedManifest = try Data(floeContentsOf: URL(fileURLWithPath: existing.rootPath).appendingPathComponent("manifest.json"))
                guard installedManifest == manifestData else { throw FloeError.validationFailed("Installed model version has different bytes") }
                return existing
            }
            throw FloeError.validationFailed("Model already installed; remove it before installing another version")
        }
        let destination = try safePath("\(scope.rawValue)/\(manifest.id)/\(manifest.version)", beneath: rootURL)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for file in manifest.files {
                let source = bundleURL.appendingPathComponent(file.path)
                let target = try safePath(file.path, beneath: staging)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: target)
            }
            // The manifest itself is the verification source, so it is not in
            // its own file list; copy it so an installed bundle stays
            // hash-verifiable after installation.
            let manifestCopy = try safePath("manifest.json", beneath: staging)
            try fileManager.copyItem(at: manifestURL, to: manifestCopy)
            try fileManager.moveItem(at: staging, to: destination)
            var models = try installedChecked()
            let record = InstalledModel(
                id: manifest.id,
                version: manifest.version,
                capability: manifest.capability,
                scope: scope,
                rootPath: destination.path,
                sha256: manifest.files.map(\.sha256).joined(separator: ":"),
                license: manifest.license
            )
            models.removeAll { $0.id == manifest.id }
            models.append(record)
            do { try persist(models) }
            catch {
                try? fileManager.moveItem(at: destination, to: staging)
                throw error
            }
            return record
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    /// Removes one model install and deletes its files.
    public func remove(id: String) throws {
        guard !mutationActive else { throw FloeError.validationFailed("Another model mutation is active") }
        var models = try installedChecked()
        guard let record = models.first(where: { $0.id == id }) else {
            throw FloeError.notFound("model \(id)")
        }
        let expected = try safePath("\(record.scope.rawValue)/\(record.id)/\(record.version)", beneath: rootURL)
        guard expected.standardizedFileURL.path == URL(fileURLWithPath: record.rootPath).standardizedFileURL.path else {
            throw FloeError.validationFailed("Installed model path does not match its ownership")
        }
        let trash = expected.deletingLastPathComponent().appendingPathComponent(".removing-\(UUID().uuidString)")
        try fileManager.moveItem(at: expected, to: trash)
        models.removeAll { $0.id == id }
        do { try persist(models) }
        catch { try? fileManager.moveItem(at: trash, to: expected); throw error }
        try fileManager.removeItem(at: trash)
    }

    public func status() -> String {
        let models = installed()
        guard !models.isEmpty else { return "no models installed" }
        return models.map {
            "\($0.id) \($0.version) capability=\($0.capability) scope=\($0.scope.rawValue) path=\($0.rootPath)"
        }.joined(separator: "\n")
    }

    /// Checks the downloadable layout before it becomes a registered install.
    /// This proves identity and bytes; runtime inference readiness is separate.
    private func validateEnhancementBundle(at root: URL, id: String, version: String, capability: String) throws {
        struct Contract: Decodable { var id: String; var version: String; var capability: String; var kind: String; var tileSize: Int }
        struct Manifest: Decodable {
            struct File: Decodable { var path: String; var sha256: String; var sizeBytes: Int64 }
            var id: String; var version: String; var capability: String; var files: [File]
        }
        let contract = try JSONDecoder().decode(Contract.self, from: Data(floeContentsOf: safePath("contract.json", beneath: root)))
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(floeContentsOf: safePath("manifest.json", beneath: root)))
        guard contract.id == id, contract.version == version, contract.capability == capability,
              contract.kind == "coreml", contract.tileSize > 0,
              manifest.id == id, manifest.version == version, manifest.capability == capability,
              Set(manifest.files.map(\.path)).count == manifest.files.count else {
            throw FloeError.validationFailed("Model catalog, manifest and runtime contract identity differ")
        }
        let paths = Set(manifest.files.map(\.path))
        guard paths.contains("contract.json"), paths.contains("LICENSE.txt"), paths.contains("PROVENANCE.json"),
              paths.contains(where: { $0.hasPrefix("model.mlmodelc/") }) else {
            throw FloeError.validationFailed("Model bundle is missing runtime files or required notices")
        }
        for file in manifest.files {
            let url = try safePath(file.path, beneath: root)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard file.sha256.count == 64, file.sha256.allSatisfy(\.isHexDigit),
                  size.map(Int64.init) == file.sizeBytes,
                  try FloeDigest.sha256Hex(ofFileAt: url).caseInsensitiveCompare(file.sha256) == .orderedSame else {
                throw FloeError.validationFailed("Model bundle byte mismatch: \(file.path)")
            }
        }
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw FloeError.validationFailed("Model bundle cannot be enumerated")
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw FloeError.validationFailed("Model bundle contains a symbolic link") }
            if values.isRegularFile == true {
                let relative = String(url.path.dropFirst(root.path.count + 1))
                guard relative == "manifest.json" || relative == ".floe-readiness.json" || paths.contains(relative) else {
                    throw FloeError.validationFailed("Unlisted model bundle member: \(relative)")
                }
            }
        }
    }

    private func safePath(_ relative: String, beneath root: URL) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.contains("\\"), !relative.contains("\0"),
              !parts.contains(".."), !parts.contains("."), !parts.contains("") else {
            throw FloeError.validationFailed("Invalid model artifact path")
        }
        var current = root.resolvingSymlinksInPath().standardizedFileURL
        for part in parts {
            current.appendPathComponent(String(part))
            if let attrs = try? fileManager.attributesOfItem(atPath: current.path),
               attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                throw FloeError.validationFailed("Model artifact path crosses a symbolic link")
            }
        }
        return current
    }

    private func persist(_ models: [InstalledModel]) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(models).write(to: manifestURL, options: .atomic)
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// `media.models`: the only model management entry point. `list` is
/// read-only; install/remove are explicit, scoped and approval-gated by the
/// normal tool policy.
public struct MediaModelsTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var action: String
        public var id: String?
        public var scope: String?
        public var capability: String?
    }

    public static let name = "media.models"
    public static let toolDescription =
        "List, install, remove or inspect skill-hub local-weight media models (interpolation, super resolution, restoration, audio). These are on-device artifacts, never cloud generation models and never AI capability claims: installing a file does not make it runnable. `list` shows installed and catalog-available entries with capability, size, license and availability; `install` requires an explicit id and scope (session, project or shared; prefer shared for large models); `remove` releases one install; `status` reports install paths. Runtime readiness is reported only by media.capabilities (runnable/unavailableReason). Downloads are verified against the signed catalog before use."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "action":{"type":"string","enum":["list","install","remove","status"]},
      "id":{"type":"string"},"scope":{"type":"string","enum":["session","project","shared"]},
      "capability":{"type":"string"}},
     "required":["action"],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let store: ModelArtifactStore
    private let catalogProvider: @Sendable () async -> ModelArtifactCatalog?

    public init(store: ModelArtifactStore, catalogProvider: @escaping @Sendable () async -> ModelArtifactCatalog?) {
        self.store = store
        self.catalogProvider = catalogProvider
    }

    public func validate(_ args: Arguments) throws {
        guard ["list", "install", "remove", "status"].contains(args.action.lowercased()) else {
            throw FloeError.validationFailed("action must be list, install, remove or status")
        }
        if args.action.lowercased() == "install" {
            guard let id = args.id, !id.isEmpty else {
                throw FloeError.validationFailed("id is required for action=install")
            }
        }
        if args.action.lowercased() == "remove" {
            guard let id = args.id, !id.isEmpty else {
                throw FloeError.validationFailed("id is required for action=remove")
            }
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let action = args.action.lowercased()
        let catalog = await catalogProvider()
        let installed = await store.installed()
        switch action {
        case "list", "status":
            var lines: [String] = []
            for model in installed {
                lines.append("installed id=\(model.id) version=\(model.version) capability=\(model.capability) scope=\(model.scope.rawValue)")
            }
            for artifact in catalog?.models ?? [] where artifact.isInstallable && !installed.contains(where: { $0.id == artifact.id }) {
                if let capability = args.capability, artifact.capability != capability { continue }
                lines.append("available id=\(artifact.id) version=\(artifact.version) capability=\(artifact.capability) bytes=\(artifact.totalBytes) license=\(artifact.license ?? "unknown")")
            }
            if lines.isEmpty { lines.append("no models installed or available") }
            lines.append("note=Installed artifacts are local-weight storage; being installed does not imply runnable. Runtime readiness is reported by media.capabilities (runnable/unavailableReason).")
            return ToolExecutionOutput(digesting: lines.joined(separator: "\n"), exitStatus: 0)
        case "install":
            guard let id = args.id, let artifact = catalog?.model(id: id) else {
                throw FloeError.notFound("model \(args.id ?? "") is not in the signed catalog")
            }
            guard let rawScope = args.scope, let scope = InstalledModel.Scope(rawValue: rawScope) else {
                throw FloeError.validationFailed("An explicit valid model install scope is required")
            }
            let record = try await store.install(artifact, scope: scope, cancellation: context.cancellation)
            return ToolExecutionOutput(
                digesting: "installed id=\(record.id) version=\(record.version) scope=\(record.scope.rawValue) path=\(record.rootPath)",
                exitStatus: 0
            )
        case "remove":
            guard let id = args.id else { throw FloeError.validationFailed("id is required") }
            try await store.remove(id: id)
            return ToolExecutionOutput(digesting: "removed id=\(id)", exitStatus: 0)
        default:
            throw FloeError.validationFailed("unsupported action \(action)")
        }
    }
}
