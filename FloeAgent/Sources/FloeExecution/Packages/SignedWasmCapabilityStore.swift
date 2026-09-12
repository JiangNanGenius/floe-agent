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
        public init(id: String, version: String, command: String, url: URL, sha256: String, minimumAppVersion: String) {
            self.id = id; self.version = version; self.command = command; self.url = url
            self.sha256 = sha256; self.minimumAppVersion = minimumAppVersion
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
        for entry in catalog.packages {
            guard entry.id.range(of: "^floe/[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil,
                  entry.command.range(of: "^floe-[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil,
                  entry.version.range(of: "^[0-9]+[.][0-9]+[.][0-9]+$", options: .regularExpression) != nil,
                  entry.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  entry.url.scheme == "https", entry.url.host != nil, entry.url.user == nil, entry.url.password == nil,
                  entry.minimumAppVersion.range(of: "^[0-9]+[.][0-9]+[.][0-9]+$", options: .regularExpression) != nil,
                  appVersion.compare(entry.minimumAppVersion, options: .numeric) != .orderedAscending,
                  ids.insert(entry.id).inserted, commands.insert(entry.command).inserted else {
                throw FloeError.validationFailed("Invalid, duplicate or incompatible WASM catalog entry")
            }
        }
        return catalog
    }
}

public actor SignedWasmCapabilityStore {
    public typealias Download = @Sendable (URL, URL) async throws -> Void
    public nonisolated let catalog: SignedWasmCatalog
    private let root: URL
    private let download: Download
    private let runtime: any WasmCommandRuntime
    private var busy = Set<String>()
    private var activeRuns: [String: Int] = [:]

    public init(catalogData: Data, signature: Data, publicKey: Data, appVersion: String, root: URL, runtime: any WasmCommandRuntime = WasmKitCommandRuntime(), download: @escaping Download) throws {
        catalog = try SignedWasmCatalog.verify(data: catalogData, signature: signature, publicKey: publicKey, appVersion: appVersion)
        self.root = root
        self.runtime = runtime
        self.download = download
    }

    public func installedIDs() -> [String] {
        catalog.packages.filter { entry in
            guard let data = try? Data(contentsOf: receiptURL(entry)),
                  let receipt = try? JSONDecoder().decode(SignedWasmCatalog.Entry.self, from: data), receipt == entry else { return false }
            let url = moduleURL(entry)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? Int.max
            return size <= 4 * 1024 * 1024 && (try? FloeDigest.sha256Hex(ofFileAt: url)) == entry.sha256
        }.map(\.id)
    }

    public func install(id: String, cancellation: CancellationToken?) async throws {
        guard let entry = catalog.packages.first(where: { $0.id == id }) else { throw FloeError.notFound("Unknown signed WASM package") }
        guard activeRuns[id, default: 0] == 0, busy.insert(id).inserted else { throw FloeError.validationFailed("Package operation already in progress") }
        defer { busy.remove(id) }
        try cancellation?.throwIfCancelled()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = root.appendingPathComponent(".stage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        try await download(entry.url, stage)
        try cancellation?.throwIfCancelled()
        let size = (try FileManager.default.attributesOfItem(atPath: stage.path)[.size] as? NSNumber)?.intValue ?? Int.max
        guard size <= 4 * 1024 * 1024, try FloeDigest.sha256Hex(ofFileAt: stage) == entry.sha256 else {
            throw FloeError.validationFailed("WASM artifact exceeds limits or failed SHA-256 verification")
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

    public func run(command: String, arguments: [String], stdin: String?, environment: [String: String], rootURL: URL, timeout: TimeInterval = 30, maxOutputBytes: Int = 256 * 1024, cancellation: CancellationToken? = nil) async -> ShellRunOutcome {
        guard let entry = catalog.packages.first(where: { $0.command == command }), installedIDs().contains(entry.id) else {
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
        return await runtime.run(moduleURL: moduleURL(entry), arguments: arguments, stdin: stdin, environment: environment, rootURL: rootURL, timeout: timeout, maxOutputBytes: maxOutputBytes, cancellation: cancellation)
    }

    private func moduleURL(_ entry: SignedWasmCatalog.Entry) -> URL { root.appendingPathComponent(entry.command + "-" + entry.version + ".wasm") }
    private func receiptURL(_ entry: SignedWasmCatalog.Entry) -> URL { root.appendingPathComponent(entry.command + ".json") }
}
