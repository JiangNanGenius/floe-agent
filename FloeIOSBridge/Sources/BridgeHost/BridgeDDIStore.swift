import Foundation
import CryptoKit
import BridgeCore

/// Downloads or imports the DDI files at runtime. Nothing is bundled in the
/// IPA. Downloads are staged, bounded and cancellable; file presence is
/// validated by size/shape, and actual mount success is still required.
@MainActor
final class BridgeDDIStore: ObservableObject {
    @Published private(set) var isDownloading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText: String?
    @Published private(set) var lastError: String?
    @Published private(set) var isImporting = false

    private var downloadTask: Task<Void, Never>?
    private var activeDownloader: BridgeDownloader?
    private var downloadGeneration: UInt64 = 0

    var method: BridgeDDIInstallMethod { BridgeDDIInstallMethod.current }

    var directory: URL {
        BridgePaths.ddiDirectory.appendingPathComponent(method.mirrorFolder, isDirectory: true)
    }

    func url(for component: BridgeDDIComponent) -> URL {
        directory.appendingPathComponent(component.rawValue)
    }

    var isComplete: Bool {
        method.components.allSatisfy { component in
            guard let size = try? FileManager.default.attributesOfItem(atPath: url(for: component).path)[.size] as? NSNumber else {
                return false
            }
            return size.int64Value >= component.minimumBytes
        }
    }

    var totalBytes: Int64 {
        method.components.reduce(0) { total, component in
            let size = try? FileManager.default.attributesOfItem(atPath: url(for: component).path)[.size] as? NSNumber
            return total + (size?.int64Value ?? 0)
        }
    }

    func cancel() {
        downloadGeneration &+= 1
        activeDownloader?.cancel()
        activeDownloader = nil
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        statusText = nil
    }

    func download() {
        guard !isDownloading else { return }
        downloadTask?.cancel()
        downloadGeneration &+= 1
        let generation = downloadGeneration
        isDownloading = true
        progress = 0
        lastError = nil
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.downloadGeneration {
                    self.isDownloading = false
                    self.statusText = nil
                }
            }
            do {
                try await self.performDownload(generation)
            } catch is CancellationError {
                guard generation == self.downloadGeneration else { return }
                self.statusText = "Download cancelled."
            } catch {
                guard generation == self.downloadGeneration else { return }
                self.lastError = error.localizedDescription
                BridgeLog.shared.append("ddi_download_failed error=\(error.localizedDescription)")
            }
        }
    }

    private func performDownload(_ generation: UInt64) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let components = method.components
        let available = try FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber
        if let available, available.int64Value < 900 * 1024 * 1024 {
            throw BridgeDDIStoreError.insufficientDisk(available.int64Value)
        }

        var records: [[String: Any]] = []
        for (index, component) in components.enumerated() {
            try Task.checkCancellation()
            guard generation == downloadGeneration else { throw CancellationError() }
            let destination = url(for: component)
            self.statusText = "\(index + 1)/\(components.count) \(component.rawValue)"
            if let size = try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber,
               size.int64Value >= component.minimumBytes {
                progress = Double(index + 1) / Double(components.count)
                records.append(try provenance(for: component, source: "cached"))
                continue
            }

            let remote = BridgeDDIStatus.mirrorURL(component: component, method: method)
            let downloader = BridgeDownloader(
                maximumBytes: component.maximumBytes,
                destinationDirectory: directory
            ) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, generation == self.downloadGeneration else { return }
                    self.progress = (Double(index) + fraction) / Double(components.count)
                }
            }
            activeDownloader = downloader
            let downloadResult: BridgeDownloader.Result
            do {
                downloadResult = try await withTaskCancellationHandler {
                    try await downloader.download(url: remote)
                } onCancel: {
                    downloader.cancel()
                }
            } catch {
                if generation == downloadGeneration { activeDownloader = nil }
                throw error
            }
            if generation == downloadGeneration { activeDownloader = nil }
            let size = downloadResult.bytes
            guard size >= component.minimumBytes, size <= component.maximumBytes else {
                try? FileManager.default.removeItem(at: downloadResult.stagedURL)
                throw BridgeDDIStoreError.size(component.rawValue, size)
            }
            let staged = downloadResult.stagedURL
            do {
                try Task.checkCancellation()
                try validate(staged, component: component)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: staged, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: staged)
                throw error
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            progress = Double(index + 1) / Double(components.count)
            records.append(try provenance(for: component, source: remote.absoluteString))
            BridgeLog.shared.append("ddi_downloaded component=\(component.rawValue) bytes=\(size)")
        }

        let record: [String: Any] = [
            "method": method.rawValue,
            "mirrorBase": BridgeDDISource.mirrorBase,
            "downloadedAt": BridgeClock.timestamp(),
            "components": records,
        ]
        BridgeAtomicFile.writeJSON(record, to: BridgePaths.ddiSourceFile)
    }

    /// Imports a folder containing the expected DDI files, e.g. a folder copied
    /// from Xcode. All files are validated in a staging directory first; the
    /// live set is only replaced when every component is present and valid.
    func importFolder(from url: URL) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        isImporting = true
        lastError = nil
        defer { isImporting = false }

        let available = try FileManager.default.attributesOfFileSystem(forPath: BridgePaths.ddiDirectory.path)[.systemFreeSize] as? NSNumber
        if let available, available.int64Value < 900 * 1024 * 1024 {
            throw BridgeDDIStoreError.insufficientDisk(available.int64Value)
        }

        let staging = BridgePaths.ddiDirectory.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        let backup = BridgePaths.ddiDirectory.appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            for component in method.components {
                let source = url.appendingPathComponent(component.rawValue)
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw BridgeDDIStoreError.importMissing(component.rawValue)
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                guard size >= component.minimumBytes, size <= component.maximumBytes else {
                    throw BridgeDDIStoreError.size(component.rawValue, size)
                }
                let staged = staging.appendingPathComponent(component.rawValue)
                try FileManager.default.copyItem(at: source, to: staged)
                try validate(staged, component: component)
            }

            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.moveItem(at: directory, to: backup)
            }
            do {
                try FileManager.default.moveItem(at: staging, to: directory)
            } catch {
                if FileManager.default.fileExists(atPath: backup.path) {
                    try? FileManager.default.moveItem(at: backup, to: directory)
                }
                throw error
            }
            try? FileManager.default.removeItem(at: backup)
        } catch {
            lastError = error.localizedDescription
            throw error
        }

        var records: [[String: Any]] = []
        for component in method.components {
            let destination = self.url(for: component)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            records.append(try provenance(for: component, source: "imported-folder"))
        }
        let record: [String: Any] = [
            "method": method.rawValue,
            "source": "imported-folder",
            "importedAt": BridgeClock.timestamp(),
            "components": records,
        ]
        BridgeAtomicFile.writeJSON(record, to: BridgePaths.ddiSourceFile)
        BridgeLog.shared.append("ddi_imported method=\(method.rawValue)")
    }

    func removeAll() {
        cancel()
        try? FileManager.default.removeItem(at: BridgePaths.ddiDirectory)
        try? FileManager.default.removeItem(at: BridgePaths.ddiSourceFile)
    }

    private func validate(_ url: URL, component: BridgeDDIComponent) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size >= component.minimumBytes, size <= component.maximumBytes else {
            throw BridgeDDIStoreError.size(component.rawValue, size)
        }
        if component.isPlist {
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dictionary = object as? [String: Any] else {
                throw BridgeDDIStoreError.invalidPlist(component.rawValue)
            }
            let hasVersion = dictionary["ProductVersion"] != nil || dictionary["ProductBuildVersion"] != nil
            let hasIdentities = dictionary["BuildIdentities"] != nil
            guard hasVersion || hasIdentities else {
                throw BridgeDDIStoreError.invalidPlist(component.rawValue)
            }
        }
    }

    private func provenance(for component: BridgeDDIComponent, source: String) throws -> [String: Any] {
        let path = url(for: component)
        let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.int64Value ?? 0
        let hash = try Self.sha256File(at: path)
        return [
            "component": component.rawValue,
            "source": source,
            "bytes": size,
            "sha256": hash,
        ]
    }

    static func sha256File(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum BridgeDDIStatus {
    static func mirrorURL(component: BridgeDDIComponent, method: BridgeDDIInstallMethod) -> URL {
        BridgeDDISource.remoteURL(for: component, method: method)
    }
}

enum BridgeDDIStoreError: LocalizedError {
    case insufficientDisk(Int64)
    case downloadStatus(String, Int)
    case size(String, Int64)
    case invalidPlist(String)
    case importMissing(String)

    var errorDescription: String? {
        switch self {
        case .insufficientDisk(let available):
            return "Not enough free space for the DDI (need about 900 MB, \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) available)."
        case .downloadStatus(let file, let status):
            return "Downloading \(file) returned HTTP \(status)."
        case .size(let file, let bytes):
            return "\(file) has an unexpected size (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))."
        case .invalidPlist(let file):
            return "\(file) is not a valid Developer Disk Image build manifest."
        case .importMissing(let file):
            return "The selected folder has no \(file)."
        }
    }
}
