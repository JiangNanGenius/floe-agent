// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit

/// Durable owned-receipt storage in a project-owned directory, using atomic
/// per-receipt files. It stores records only; the existing session worker
/// stays the single executor/poller, so this is not a parallel task registry.
/// Terminal records older than the retention window are pruned on write.
public actor AudioStemCloudFileReceiptStore: AudioStemCloudReceiptStore {
    public static let directoryName = ".stem-jobs"
    public static let retentionSeconds = 30 * 24 * 3600
    public static let maximumReceiptBytes = 8_192
    private let directory: URL
    private let projectID: UUID
    public init(root: URL, projectID: UUID) throws {
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonical.appendingPathComponent(Self.directoryName)
        guard candidate.path.hasPrefix(canonical.path + "/") else {
            throw AudioPCMProcessingError.invalidInput("invalid stem job directory")
        }
        directory = candidate
        self.projectID = projectID
    }
    public func save(_ receipt: AudioStemCloudReceipt) async throws {
        try receipt.validated()
        guard receipt.projectID == projectID, Self.safeName(receipt.remoteJobID) else {
            throw AudioStemCloudError.persistence("the receipt does not belong to this project")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(receipt)
        guard data.count <= Self.maximumReceiptBytes else { throw AudioStemCloudError.persistence("receipt exceeds its bound") }
        try data.write(to: directory.appendingPathComponent(receipt.remoteJobID + ".json"), options: .atomic)
        prune()
    }
    public func owned(projectID: UUID, clipID: UUID) async throws -> AudioStemCloudReceipt? {
        try await loadAll().filter { $0.projectID == projectID && $0.clipID == clipID && !$0.isTerminal && !$0.remoteJobID.isEmpty }
            .max { $0.updatedAt < $1.updatedAt }
    }
    public func outstanding(projectID: UUID) async throws -> [AudioStemCloudReceipt] {
        try await loadAll().filter { $0.projectID == projectID && !$0.isTerminal && !$0.remoteJobID.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    public func load(remoteJobID: String) async throws -> AudioStemCloudReceipt? {
        try await loadAll().first { $0.remoteJobID == remoteJobID }
    }
    private func loadAll() throws -> [AudioStemCloudReceipt] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        var result: [AudioStemCloudReceipt] = []
        for url in urls where url.pathExtension == "json" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= Self.maximumReceiptBytes,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let receipt = try? Self.decoder.decode(AudioStemCloudReceipt.self, from: data),
                  receipt.projectID == projectID, receipt.remoteJobID == url.deletingPathExtension().lastPathComponent,
                  Self.safeName(receipt.remoteJobID), (try? receipt.validated()) != nil else { continue }
            result.append(receipt)
        }
        return result
    }
    private func prune() {
        let cutoff = Date(timeIntervalSinceNow: -TimeInterval(Self.retentionSeconds))
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let receipt = try? Self.decoder.decode(AudioStemCloudReceipt.self, from: data),
                  receipt.isTerminal, receipt.updatedAt < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
    private static func safeName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }
    }
    private static let encoder: JSONEncoder = { let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; return value }()
    private static let decoder = JSONDecoder()
}
