// FloeExecution — Capability installer.
// Routes apt/pkg requests to the reviewed primitive that owns each kind.
// Python packages use the managed pip path; skills/fonts/models reuse the
// app's existing stores through injected protocols. Every install is
// recorded in a small JSON ledger for honest `apt list --installed`.

import Foundation
import FloeCore
import FloeTools

public protocol CapabilitySkillInstalling: Sendable {
    func installCapabilitySkill(id: String) async throws
}

public protocol CapabilityFontInstalling: Sendable {
    func installCapabilityFont(downloadedFile: URL, sha256: String?) async throws
}

public protocol CapabilityModelInstalling: Sendable {
    func installCapabilityModel(id: String) async throws
}

public actor CapabilityInstaller {
    public struct Receipt: Sendable, Codable {
        public var id: String
        public var kind: CapabilityCatalog.Kind
        public var tier: CapabilityCatalog.Tier
        public var detail: String
        public var installedAt: Date
    }

    public nonisolated let catalog: CapabilityCatalog

    private let pythonInstaller: ManagedPythonInstallService?
    private let http: HTTPRequestService
    private let packagesRoot: URL
    private let skillInstaller: (any CapabilitySkillInstalling)?
    private let fontInstaller: (any CapabilityFontInstalling)?
    private let wasmStore: SignedWasmCapabilityStore?
    private let modelInstaller: (any CapabilityModelInstalling)?
    private var ledger: [String: Receipt] = [:]
    private var ledgerLoaded = false

    public init(
        catalog: CapabilityCatalog,
        pythonInstaller: ManagedPythonInstallService?,
        http: HTTPRequestService,
        packagesRoot: URL,
        skillInstaller: (any CapabilitySkillInstalling)? = nil,
        fontInstaller: (any CapabilityFontInstalling)? = nil,
        modelInstaller: (any CapabilityModelInstalling)? = nil,
        wasmStore: SignedWasmCapabilityStore? = nil,
        toolCatalog: ToolCapabilityCatalog? = nil
    ) {
        var merged = catalog
        if let toolCatalog {
            merged.entries += CapabilityCatalog.shellToolEntries(from: toolCatalog)
        }
        if let wasmStore {
            merged.entries += wasmStore.catalog.packages.map { entry in
                // Interpreter-class entries carry a raised signed ceiling; say so
                // instead of presenting a 34 MiB interpreter as a small utility.
                let interpreter = entry.resolvedModuleMaxBytes > WasmPackageLimits.defaultModuleMaxBytes
                let summary = interpreter
                    ? "Signed WASI interpreter \(entry.command) \(entry.version); first start can take seconds"
                    : "Signed WASI command " + entry.command
                let bare = entry.command.hasPrefix("floe-") ? String(entry.command.dropFirst("floe-".count)) : entry.command
                return .init(id: entry.id, kind: .wasmCommand, tier: .wasm, summary: summary,
                             url: entry.url.absoluteString, sha256: entry.sha256, aliases: [entry.command, bare])
            }
        }
        self.catalog = merged
        self.wasmStore = wasmStore
        self.pythonInstaller = pythonInstaller
        self.http = http
        self.packagesRoot = packagesRoot
        self.skillInstaller = skillInstaller
        self.fontInstaller = fontInstaller
        self.modelInstaller = modelInstaller
    }

    public func search(_ query: String) -> [CapabilityCatalog.Entry] { catalog.search(query) }
    public func show(_ id: String) -> CapabilityCatalog.Entry? { catalog.entry(id: id) }
    public func allEntries() -> [CapabilityCatalog.Entry] { catalog.entries }

    public func installedIDs(environment: ToolEnvironment? = nil) async -> [String] {
        loadLedgerIfNeeded()
        var ids = Set(ledger.values.filter { $0.kind != .pythonPackage && $0.kind != .wasmCommand && $0.kind != .shellTool }.map(\.id))
        let distributions: Set<String>
        if let pythonInstaller {
            distributions = Set((await pythonInstaller.installedDistributions(environment: environment)).map(Self.normalizedDistribution))
        } else {
            distributions = []
        }
        for entry in catalog.entries(kind: .pythonPackage) {
            if let distribution = entry.distributionName, distributions.contains(Self.normalizedDistribution(distribution)) {
                ids.insert(entry.id)
            }
        }
        var wasmInstalled = Set<String>()
        if let wasmStore {
            wasmInstalled = Set(await wasmStore.installedIDs())
            ids.formUnion(wasmInstalled)
        }
        // Reviewed tool routes: a direct command exists the moment the shell
        // engine ships. Precompiled tools count as installed only through the
        // verified signed store; remote/unsupported tools never do.
        for entry in catalog.entries(kind: .shellTool) {
            switch entry.route {
            case .direct?:
                ids.insert(entry.id)
            case .floePrecompiled?:
                if let signedIDs = entry.signedCatalogIDs, signedIDs.contains(where: { wasmInstalled.contains($0) }) {
                    ids.insert(entry.id)
                }
            case .remote?, .unsupported?, .none:
                break
            }
        }
        return ids.sorted()
    }

    public func install(
        id: String,
        purpose: String?,
        capabilities: [String],
        cancellation: CancellationToken?,
        environment: ToolEnvironment? = nil
    ) async throws -> Receipt {
        loadLedgerIfNeeded()
        guard let entry = catalog.entry(id: id) else {
            throw FloeError.notFound("capability \(id) is not in the catalog")
        }
        if entry.tier != .bundled {
            guard let purpose, !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FloeError.validationFailed("purpose is required for network capability installs")
            }
        }
        let receipt: Receipt
        switch entry.kind {
        case .pythonPackage:
            guard let pythonInstaller else {
                throw FloeError.invalidConfiguration("The bundled Python runtime is unavailable in this build")
            }
            guard let spec = entry.spec else {
                throw FloeError.invalidConfiguration("catalog entry \(entry.id) has no exact package spec")
            }
            let distribution = Self.normalizedDistribution(entry.distributionName ?? "")
            let installed = Set((await pythonInstaller.installedDistributions(environment: environment)).map(Self.normalizedDistribution))
            if entry.tier == .bundled, installed.contains(distribution) {
                receipt = Receipt(id: entry.id, kind: entry.kind, tier: entry.tier,
                                  detail: "already installed (bundled)", installedAt: Date())
                break
            }
            guard entry.tier != .bundled else {
                throw FloeError.invalidConfiguration("Bundled package is missing; repair the app runtime instead of downloading it silently")
            }
            switch await pythonInstaller.install(specs: [spec], cancellation: cancellation, environment: environment) {
            case .ok(let output):
                receipt = Receipt(id: entry.id, kind: entry.kind, tier: entry.tier,
                                  detail: output.isEmpty ? "installed \(spec)" : "installed \(spec)", installedAt: Date())
            case .failed(let message):
                throw FloeError.validationFailed("Package install failed: \(message)")
            case .timedOut:
                throw FloeError.validationFailed("Package install timed out")
            case .cancelled:
                throw FloeError.cancelled
            }
        case .skill:
            guard let skillInstaller else {
                throw FloeError.invalidConfiguration("Skill installation is unavailable in this build")
            }
            try await skillInstaller.installCapabilitySkill(id: entry.skillID ?? entry.id)
            receipt = Receipt(id: entry.id, kind: entry.kind, tier: entry.tier,
                              detail: "skill installed", installedAt: Date())
        case .font:
            guard let fontInstaller else {
                throw FloeError.invalidConfiguration("Font installation is unavailable in this build")
            }
            guard let urlString = entry.url, let url = URL(string: urlString) else {
                throw FloeError.invalidConfiguration("catalog entry \(entry.id) has no font URL")
            }
            let destination = packagesRoot.appendingPathComponent("downloads", isDirectory: true)
                .appendingPathComponent(entry.id.replacingOccurrences(of: "/", with: "-"))
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            _ = try await http.download(url: url, timeout: 90, maxBytes: 32 * 1024 * 1024, to: destination, cancellation: cancellation)
            if let expected = entry.sha256 {
                let actual = try FloeDigest.sha256Hex(ofFileAt: destination)
                guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                    try? FileManager.default.removeItem(at: destination)
                    throw FloeError.validationFailed("Font download failed SHA-256 verification")
                }
            }
            try await fontInstaller.installCapabilityFont(downloadedFile: destination, sha256: entry.sha256)
            receipt = Receipt(id: entry.id, kind: entry.kind, tier: entry.tier,
                              detail: "font installed", installedAt: Date())
        case .model:
            guard let modelInstaller else {
                throw FloeError.invalidConfiguration("Model installation is unavailable in this build")
            }
            try await modelInstaller.installCapabilityModel(id: entry.modelID ?? entry.id)
            receipt = Receipt(id: entry.id, kind: entry.kind, tier: entry.tier,
                              detail: "model installed", installedAt: Date())
        case .debData:
            throw FloeError.validationFailed("Use `dpkg -x <file.deb> <dir>` for data-only .deb payloads; apt does not install executable packages on iOS")
        case .shellTool:
            receipt = try installShellTool(entry)
        case .wasmCommand:
            guard let wasmStore else { throw FloeError.invalidConfiguration("Signed WASM catalog is unavailable") }
            try await wasmStore.install(id: entry.id, cancellation: cancellation)
            receipt = Receipt(id: entry.id, kind: entry.kind, tier: entry.tier, detail: "signed WASM command installed", installedAt: Date())
        }
        record(receipt)
        return receipt
    }

    /// Reviewed tool routes never fake an install. A direct command already
    /// exists, a pending artifact must name its gap, and remote/unsupported
    /// routes refuse instead of pretending the tool can run locally.
    private func installShellTool(_ entry: CapabilityCatalog.Entry) throws -> Receipt {
        switch entry.route {
        case .direct?:
            return Receipt(id: entry.id, kind: entry.kind, tier: entry.tier,
                           detail: "already available in the built-in shell; nothing was downloaded",
                           installedAt: Date())
        case .floePrecompiled?:
            throw FloeError.validationFailed("\(entry.id) is a Floe precompiled tool whose signed artifact is not available yet; install it after the artifact is published and signed")
        case .remote?:
            throw FloeError.validationFailed("\(entry.id) is remote-only: it runs on a paired host with the tool on PATH, not on this device")
        case .unsupported?, .none:
            throw FloeError.validationFailed("\(entry.id) has no supported route on this device; use an approved remote host")
        }
    }

    public func remove(id: String, environment: ToolEnvironment? = nil) async throws -> Receipt {
        loadLedgerIfNeeded()
        guard let entry = catalog.entry(id: id) else {
            throw FloeError.notFound("capability \(id) is not in the catalog")
        }
        switch entry.kind {
        case .pythonPackage:
            guard let pythonInstaller else {
                throw FloeError.invalidConfiguration("The bundled Python runtime is unavailable in this build")
            }
            guard entry.tier != .bundled else {
                throw FloeError.validationFailed("\(entry.id) ships with the app and cannot be removed")
            }
            guard let distribution = entry.distributionName else {
                throw FloeError.invalidConfiguration("catalog entry \(entry.id) has no distribution name")
            }
            switch await pythonInstaller.uninstall(distribution: distribution, environment: environment) {
            case .ok:
                break
            case .failed(let message):
                throw FloeError.validationFailed("Package removal failed: \(message)")
            case .timedOut:
                throw FloeError.validationFailed("Package removal timed out")
            case .cancelled:
                throw FloeError.cancelled
            }
            ledger.removeValue(forKey: entry.id)
            persistLedger()
            return Receipt(id: entry.id, kind: entry.kind, tier: entry.tier,
                           detail: "uninstalled \(distribution)", installedAt: Date())
        case .skill:
            throw FloeError.validationFailed("Use skill.manage action=remove for workflow guides")
        case .font:
            throw FloeError.validationFailed("Use font.remove with the digest returned by font.list")
        case .model:
            throw FloeError.validationFailed("Use the model manager UI to remove downloaded models")
        case .wasmCommand:
            guard let wasmStore else { throw FloeError.invalidConfiguration("Signed WASM catalog is unavailable") }
            try await wasmStore.remove(id: entry.id)
            ledger.removeValue(forKey: entry.id)
            persistLedger()
            return Receipt(id: entry.id, kind: entry.kind, tier: entry.tier, detail: "WASM command removed", installedAt: Date())
        case .debData:
            ledger.removeValue(forKey: entry.id)
            persistLedger()
            return Receipt(id: entry.id, kind: entry.kind, tier: entry.tier,
                           detail: "ledger entry removed", installedAt: Date())
        case .shellTool:
            switch entry.route {
            case .direct?:
                throw FloeError.validationFailed("\(entry.id) ships inside the app shell and cannot be removed")
            case .floePrecompiled?:
                throw FloeError.validationFailed("\(entry.id) is removed with the signed catalog capability that provides its artifact")
            case .remote?, .unsupported?, .none:
                throw FloeError.validationFailed("\(entry.id) was never installed on this device; there is nothing to remove")
            }
        }
    }

    // MARK: - Ledger

    /// Fetches a catalog artifact (font/deb/wasm/data) to a directory without
    /// installing it. Python packages use network.download + the managed pip
    /// path instead.
    public func download(id: String, to destinationDirectory: URL, cancellation: CancellationToken? = nil) async throws -> URL {
        guard let entry = catalog.entry(id: id) else {
            throw FloeError.notFound("capability \(id) is not in the catalog")
        }
        guard let urlString = entry.url, let url = URL(string: urlString) else {
            throw FloeError.validationFailed("\(entry.id) has no downloadable artifact; install it through apt install")
        }
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destination = destinationDirectory.appendingPathComponent(url.lastPathComponent)
        _ = try await http.download(url: url, timeout: 120, maxBytes: 64 * 1024 * 1024, to: destination, cancellation: cancellation)
        if let expected = entry.sha256 {
            let actual = try FloeDigest.sha256Hex(ofFileAt: destination)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                try? FileManager.default.removeItem(at: destination)
                throw FloeError.validationFailed("Download failed SHA-256 verification")
            }
        }
        return destination
    }

    private static func normalizedDistribution(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "[-_.]+", with: "-", options: .regularExpression)
    }

    private var ledgerURL: URL {
        packagesRoot.appendingPathComponent("installed-capabilities.json")
    }

    private func loadLedgerIfNeeded() {
        guard !ledgerLoaded else { return }
        ledgerLoaded = true
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(floeContentsOf: ledgerURL),
              let decoded = try? decoder.decode([String: Receipt].self, from: data) else { return }
        ledger = decoded
    }

    private func record(_ receipt: Receipt) {
        ledger[receipt.id] = receipt
        persistLedger()
    }

    private func persistLedger() {
        do {
            try FileManager.default.createDirectory(at: packagesRoot, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(ledger)
            try data.write(to: ledgerURL, options: .atomic)
        } catch {
            FloeLogger(category: .tools).error("capabilityLedgerWriteFailed error=\(error.localizedDescription)")
        }
    }
}
