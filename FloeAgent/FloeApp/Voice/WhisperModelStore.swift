// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CryptoKit

actor WhisperModelStore {
    static let shared = WhisperModelStore()
    struct Manifest: Decodable, Sendable {
        struct Asset: Decodable, Sendable { let path: String; let url: URL; let sha256: String; let byteCount: Int64 }
        let schemaVersion: Int
        let id: String
        let title: String
        let sourceRevision: String
        let files: [Asset]
    }
    enum Failure: Error, LocalizedError {
        case unavailable, corrupt, busy
        var errorDescription: String? {
            switch self {
            case .unavailable: "Whisper 模型尚未安装。"
            case .corrupt: "Whisper 资源不完整或校验失败，请重新下载。"
            case .busy: "语音识别正在使用模型，请结束后再操作。"
            }
        }
    }
    private var leases = Set<UUID>()
    private var installing = false
    private func root() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FloeAgent/SpeechModels", isDirectory: true)
    }
    func manifest() throws -> Manifest {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "Whisper") else { throw Failure.unavailable }
        let value = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard value.schemaVersion == 1, value.id == "whisper-small-multilingual", !value.files.isEmpty,
              Set(value.files.map(\.path)).count == value.files.count,
              value.files.allSatisfy({ asset in
                  !asset.path.hasPrefix("/") && !asset.path.contains("\\") && !asset.path.split(separator: "/").contains("..") &&
                  asset.url.scheme == "https" && asset.url.host == "huggingface.co" && asset.byteCount > 0 &&
                  asset.sha256.count == 64 && asset.sha256.allSatisfy(\.isHexDigit)
              }) else { throw Failure.corrupt }
        return value
    }
    private func location(_ manifest: Manifest) throws -> URL {
        try root().appendingPathComponent(manifest.id + "-" + manifest.sourceRevision, isDirectory: true)
    }
    func isInstalled() -> Bool {
        guard let value = try? manifest(), let folder = try? location(value) else { return false }
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("installed.json").path)
    }
    func acquire() throws -> (UUID, URL) {
        guard !installing, leases.isEmpty, isInstalled() else { throw Failure.unavailable }
        let value = try manifest(), folder = try location(value)
        for asset in value.files { try verify(folder.appendingPathComponent(asset.path), asset: asset) }
        let lease = UUID(); leases.insert(lease)
        return (lease, folder)
    }
    func release(_ lease: UUID) { leases.remove(lease) }
    func remove() throws {
        guard leases.isEmpty, !installing else { throw Failure.busy }
        let folder = try location(manifest())
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
    func install(progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard !installing, leases.isEmpty else { throw Failure.busy }
        installing = true; defer { installing = false }
        let manifest = try manifest(), base = try root(), destination = try location(manifest)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let staging = base.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let total = manifest.files.reduce(Int64(0)) { $0 + $1.byteCount }
        if let free = try base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < total * 2 { throw CocoaError(.fileWriteOutOfSpace) }
        var completed: Int64 = 0
        for asset in manifest.files {
            try Task.checkCancellation()
            let (temporary, response) = try await URLSession.shared.download(from: asset.url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw Failure.corrupt }
            try verify(temporary, asset: asset)
            let target = staging.appendingPathComponent(asset.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporary, to: target)
            completed += asset.byteCount; progress(completed, total)
        }
        try Task.checkCancellation()
        try Data(manifest.sourceRevision.utf8).write(to: staging.appendingPathComponent("installed.json"), options: .atomic)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else { try FileManager.default.moveItem(at: staging, to: destination) }
    }
    private func verify(_ url: URL, asset: Manifest.Asset) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == asset.byteCount else { throw Failure.corrupt }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256 else { throw Failure.corrupt }
    }
}
#endif
