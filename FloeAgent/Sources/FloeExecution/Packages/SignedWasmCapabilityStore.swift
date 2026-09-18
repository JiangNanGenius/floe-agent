import Foundation
import Crypto
import FloeCore
import FloeTools

public struct SignedWasmCatalog: Codable, Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        public var version: String
        public var command: String
        public var url: URL
        public var sha256: String
        public var minimumAppVersion: String
        /// Reviewed per-package overrides. Absent for utility packages, which
        /// keep the historical defaults exactly.
        public var moduleMaxBytes: Int?
        public var memoryMaxBytes: Int?
        public var defaultTimeoutSeconds: Int?
        public init(id: String, version: String, command: String, url: URL, sha256: String, minimumAppVersion: String,
                    moduleMaxBytes: Int? = nil, memoryMaxBytes: Int? = nil, defaultTimeoutSeconds: Int? = nil) {
            self.id = id; self.version = version; self.command = command; self.url = url
            self.sha256 = sha256; self.minimumAppVersion = minimumAppVersion
            self.moduleMaxBytes = moduleMaxBytes; self.memoryMaxBytes = memoryMaxBytes
            self.defaultTimeoutSeconds = defaultTimeoutSeconds
        }

        public var resolvedModuleMaxBytes: Int { moduleMaxBytes ?? WasmPackageLimits.defaultModuleMaxBytes }
        public var resolvedMemoryMaxBytes: Int { memoryMaxBytes ?? WasmPackageLimits.defaultMemoryMaxBytes }
        public var resolvedDefaultTimeoutSeconds: Int { defaultTimeoutSeconds ?? Int(WasmPackageLimits.defaultTimeoutSeconds) }

        /// The activation receipt is written from the catalog entry that was
        /// installed. Later catalog revisions may add optional limits, so the
        /// comparison is the immutable identity of the artifact, not the whole
        /// decoded struct.
        func matchesReceipt(_ receipt: Entry) -> Bool {
            id == receipt.id && version == receipt.version && command == receipt.command
                && url == receipt.url && sha256 == receipt.sha256
                && minimumAppVersion == receipt.minimumAppVersion
        }
    }
    public var schemaVersion: Int
    public var packages: [Entry]
    public init(packages: [Entry]) { self.schemaVersion = 1; self.packages = packages }

    public static func verify(data: Data, signature: Data, publicKey: Data, appVersion: String) throws -> SignedWasmCatalog {
        guard data.count <= 512 * 1024,
              try Curve25519.Signing.PublicKey(rawRepresentation: publicKey).isValidSignature(signature, for: Data("FLOE-CAPABILITY-CATALOG-V1\n".utf8) + data) else {
            throw FloeError.validationFailed("WASM catalog signature verification failed")
        }
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.schemaVersion == 1, catalog.packages.count <= 256 else { throw FloeError.validationFailed("Unsupported WASM catalog") }
        var ids = Set<String>(), commands = Set<String>()
        var supported: [Entry] = []
        for entry in catalog.packages {
            guard entry.id.range(of: "^floe/[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil,
                  entry.command.range(of: "^floe-[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil,
                  entry.version.range(of: "^[0-9]+[.][0-9]+[.][0-9]+$", options: .regularExpression) != nil,
                  entry.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  entry.url.scheme == "https", entry.url.host != nil, entry.url.user == nil, entry.url.password == nil,
                  entry.minimumAppVersion.range(of: "^[0-9]+[.][0-9]+[.][0-9]+$", options: .regularExpression) != nil,
                  ids.insert(entry.id).inserted, commands.insert(entry.command).inserted else {
                throw FloeError.validationFailed("Invalid, duplicate or incompatible WASM catalog entry")
            }
            // A signed entry that requires a newer app is skipped, never fatal:
            // one forward-dated interpreter entry must not invalidate the whole
            // catalog for an older build that can still use the other packages.
            guard appVersion.compare(entry.minimumAppVersion, options: .numeric) != .orderedAscending else { continue }
            if let moduleMaxBytes = entry.moduleMaxBytes { try WasmPackageLimits.validateModuleMaxBytes(moduleMaxBytes) }
            if let memoryMaxBytes = entry.memoryMaxBytes { try WasmPackageLimits.validateMemoryMaxBytes(memoryMaxBytes) }
            if let defaultTimeoutSeconds = entry.defaultTimeoutSeconds { try WasmPackageLimits.validateTimeoutSeconds(defaultTimeoutSeconds) }
            supported.append(entry)
        }
        return SignedWasmCatalog(packages: supported)
    }
}

public actor SignedWasmCapabilityStore {
    /// Downloads one artifact to a staged path. The caller's cancellation
    /// token is passed in so a shell command that started the install can
    /// abort the transfer cooperatively instead of holding the shell worker.
    public typealias Download = @Sendable (URL, URL, CancellationToken?) async throws -> Void
    /// Download variant used by the app adapter: the store supplies the
    /// signed entry's `moduleMaxBytes` so the transfer itself is bounded,
    /// while `Download` remains for callers that only implement bytes.
    public typealias BoundedDownload = @Sendable (URL, URL, Int, CancellationToken?) async throws -> Void
    public nonisolated let catalog: SignedWasmCatalog
    private let root: URL
    private let download: BoundedDownload
    private let runtime: any WasmCommandRuntime
    private var busy = Set<String>()
    private var activeRuns: [String: Int] = [:]

    public init(catalogData: Data, signature: Data, publicKey: Data, appVersion: String, root: URL, runtime: any WasmCommandRuntime = WasmKitCommandRuntime(), download: @escaping Download) throws {
        try self.init(catalogData: catalogData, signature: signature, publicKey: publicKey, appVersion: appVersion, root: root, runtime: runtime, boundedDownload: { url, destination, _, cancellation in
            try await download(url, destination, cancellation)
        })
    }

    public init(catalogData: Data, signature: Data, publicKey: Data, appVersion: String, root: URL, runtime: any WasmCommandRuntime = WasmKitCommandRuntime(), boundedDownload: @escaping BoundedDownload) throws {
        catalog = try SignedWasmCatalog.verify(data: catalogData, signature: signature, publicKey: publicKey, appVersion: appVersion)
        self.root = root
        self.runtime = runtime
        self.download = boundedDownload
    }

    public func installedIDs() -> [String] {
        catalog.packages.filter { entry in
            guard isInstalled(entry) else { return false }
            return (try? FloeDigest.sha256Hex(ofFileAt: moduleURL(entry))) == entry.sha256
        }.map(\.id)
    }

    /// Receipt and bounds check without hashing the module. The caller that is
    /// about to execute still verifies the digest exactly once, which matters
    /// for interpreter-class modules of tens of megabytes.
    private func isInstalled(_ entry: SignedWasmCatalog.Entry) -> Bool {
        guard let data = try? Data(contentsOf: receiptURL(entry)),
              let receipt = try? JSONDecoder().decode(SignedWasmCatalog.Entry.self, from: data), entry.matchesReceipt(receipt) else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: moduleURL(entry).path)[.size] as? NSNumber)?.intValue ?? Int.max
        return size <= entry.resolvedModuleMaxBytes
    }

    public func install(id: String, cancellation: CancellationToken?) async throws {
        guard let entry = catalog.packages.first(where: { $0.id == id }) else { throw FloeError.notFound("Unknown signed WASM package") }
        guard activeRuns[id, default: 0] == 0, busy.insert(id).inserted else { throw FloeError.validationFailed("Package operation already in progress") }
        defer { busy.remove(id) }
        try cancellation?.throwIfCancelled()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = root.appendingPathComponent(".stage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        // The bounded downloader contract receives the entry's signed limit;
        // the post-transfer check below is the authoritative gate.
        try await download(entry.url, stage, entry.resolvedModuleMaxBytes, cancellation)
        try cancellation?.throwIfCancelled()
        let size = (try? FileManager.default.attributesOfItem(atPath: stage.path)[.size] as? NSNumber)?.intValue ?? Int.max
        guard size <= entry.resolvedModuleMaxBytes, try FloeDigest.sha256Hex(ofFileAt: stage) == entry.sha256 else {
            throw FloeError.validationFailed("WASM artifact exceeds its signed size limit or failed SHA-256 verification")
        }
        let header = try FileHandle(forReadingFrom: stage)
        let magic = try header.read(upToCount: 8)
        try header.close()
        guard magic == Data([0,97,115,109,1,0,0,0]) else { throw FloeError.validationFailed("Artifact is not a WASM module") }
        // Versioned immutable artifacts precede the small atomic activation receipt.
        let destination = moduleURL(entry)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try FloeDigest.sha256Hex(ofFileAt: destination) == entry.sha256 else {
                throw FloeError.validationFailed("Existing immutable WASM artifact differs")
            }
        } else { try FileManager.default.moveItem(at: stage, to: destination) }
        try JSONEncoder().encode(entry).write(to: receiptURL(entry), options: .atomic)
    }

    public func remove(id: String) throws {
        guard let entry = catalog.packages.first(where: { $0.id == id }) else { throw FloeError.notFound("Unknown WASM package") }
        guard !busy.contains(id), activeRuns[id, default: 0] == 0 else { throw FloeError.validationFailed("Package is currently in use") }
        // Removing the activation receipt makes the command unavailable immediately.
        if FileManager.default.fileExists(atPath: receiptURL(entry).path) { try FileManager.default.removeItem(at: receiptURL(entry)) }
        if FileManager.default.fileExists(atPath: moduleURL(entry).path) { try FileManager.default.removeItem(at: moduleURL(entry)) }
    }

    public func run(command: String, arguments: [String], stdin: String?, environment: [String: String], rootURL: URL, workingDirectory: String = ".", timeout: TimeInterval? = nil, maxOutputBytes: Int = 256 * 1024, cancellation: CancellationToken? = nil) async -> ShellRunOutcome {
        guard let entry = catalog.packages.first(where: { $0.command == command }), isInstalled(entry) else {
            return .failed(message: "WASM command is not installed; install its signed capability with apt")
        }
        guard !busy.contains(entry.id), activeRuns.values.reduce(0, +) < 4 else {
            return .failed(message: "WASM package is being changed or all execution slots are occupied")
        }
        activeRuns[entry.id, default: 0] += 1
        defer {
            activeRuns[entry.id, default: 0] -= 1
            if activeRuns[entry.id] == 0 { activeRuns.removeValue(forKey: entry.id) }
        }
        guard (try? FloeDigest.sha256Hex(ofFileAt: moduleURL(entry))) == entry.sha256 else {
            return .failed(message: "Installed WASM package failed integrity verification")
        }
        let budget = timeout ?? TimeInterval(entry.resolvedDefaultTimeoutSeconds)
        return await runtime.run(moduleURL: moduleURL(entry), arguments: arguments, stdin: stdin, environment: environment, rootURL: rootURL, workingDirectory: workingDirectory, timeout: budget, maxOutputBytes: maxOutputBytes, moduleMaxBytes: entry.resolvedModuleMaxBytes, memoryMaxBytes: entry.resolvedMemoryMaxBytes, cancellation: cancellation)
    }

    private func moduleURL(_ entry: SignedWasmCatalog.Entry) -> URL { root.appendingPathComponent(entry.command + "-" + entry.version + ".wasm") }
    private func receiptURL(_ entry: SignedWasmCatalog.Entry) -> URL { root.appendingPathComponent(entry.command + ".json") }
}
