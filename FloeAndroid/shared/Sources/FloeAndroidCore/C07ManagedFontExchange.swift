// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools
import FloeAndroidDataExchange

/// Font bytes are a dedicated backup resource, not credentials/configuration.
/// App validation runs before live restore changes; adoption participates in
/// the existing C07 finalization/rollback journal using its exact restoreID.
enum C07ManagedFontExchange {
    struct Record: Decodable, Sendable { let id: String; let bytes: Int64 }
    struct Catalog: Decodable, Sendable { let schema: Int; let fonts: [Record] }
    struct Snapshot: Sendable {
        let directory: URL
        let records: [Record]
        let catalogSHA256: String
    }
    static func filesRoot(_ context: C07DataExchangeContext) -> URL {
        URL(fileURLWithPath: context.rootPath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("files", isDirectory: true)
    }
    static func request(context: C07DataExchangeContext, method: String,
                        exchangeID: UUID, catalogSHA256: String? = nil, allowMissing: Bool? = nil) async throws -> Data {
        var object: [String: String] = ["method": method, "ownerScope": "dataExchange",
            "exchangeID": exchangeID.uuidString.lowercased()]
        if let catalogSHA256 { object["catalogSHA256"] = catalogSHA256 }
        if let allowMissing { object["allowMissing"] = allowMissing ? "true" : "false" }
        let data = try JSONEncoder().encode(object)
        // The ordinary host pump binds after actual native root readiness.
        for _ in 0..<20 {
            if FontHostMailbox.shared.isReady(epoch: context.epoch) { break }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
        let reply = try await FontHostMailbox.shared.submit(epoch: context.epoch,
            request: data, cancellation: CancellationToken(), recoveryWork: context.retainedWorkToken)
        guard let value = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              value["ok"] as? Bool == true else {
            throw C07DataExchangeError.storageUnavailable("fontResourceOperation")
        }
        return reply
    }
    private static func catalog(_ url: URL, sha256: String) throws -> Catalog {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let bytes = try file.read(upToCount: 262145) ?? Data()
        guard bytes.count <= 262144, C07Digest.sha256(bytes) == sha256 else {
            throw C07DataExchangeError.invalidManifest("fontCatalogDigest")
        }
        let value = try JSONDecoder().decode(Catalog.self, from: bytes)
        guard value.schema == 1, value.fonts.count <= 256,
              Set(value.fonts.map(\.id)).count == value.fonts.count,
              value.fonts.allSatisfy({ record in
                  record.id.utf8.count == 64 && record.id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
                    && record.bytes >= 12 && record.bytes <= 32 * 1024 * 1024
              }), value.fonts.reduce(Int64(0), { $0 + $1.bytes }) <= 128 * 1024 * 1024 else {
            throw C07DataExchangeError.invalidManifest("fontCatalogShape")
        }
        return value
    }
    static func snapshot(context: C07DataExchangeContext) async throws -> Snapshot {
        let id = UUID()
        let reply = try await request(context: context, method: "snapshot.export", exchangeID: id)
        let dir = filesRoot(context).appendingPathComponent("FontBackupSnapshotsV1/" + id.uuidString.lowercased())
        var handedOff = false
        defer { if !handedOff { try? FileManager.default.removeItem(at: dir) } }
        let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
        guard object?["snapshotID"] as? String == id.uuidString.lowercased(),
              let sha = object?["catalogSHA256"] as? String else {
            throw C07DataExchangeError.invalidManifest("fontSnapshotReceipt")
        }
        let value = try catalog(dir.appendingPathComponent("catalog.json"), sha256: sha)
        guard object?["count"] as? Int == value.fonts.count else {
            throw C07DataExchangeError.invalidManifest("fontSnapshotCount")
        }
        handedOff = true
        return Snapshot(directory: dir, records: value.fonts, catalogSHA256: sha)
    }
    static func prepare(context: C07DataExchangeContext, staged: C07StagedOwnedData,
                        restoreID: UUID, alreadyPrepared: Bool = false) async throws -> Int? {
        let items = staged.artifacts.filter { $0.record.role == .managedFont }
        if items.isEmpty { return nil } // Existing valid packages remain unchanged.
        guard let manifest = items.first(where: { $0.record.logicalPath == "catalog.json" }),
              manifest.record.byteCount <= 262144,
              Set(items.map { $0.record.logicalPath }).count == items.count else {
            throw C07DataExchangeError.invalidManifest("fontSnapshotManifest")
        }
        let parsed = try catalog(manifest.url, sha256: manifest.record.sha256)
        let expected = Set(parsed.fonts.map { $0.id + ".ttf" } + ["catalog.json"])
        guard Set(items.map { $0.record.logicalPath }) == expected else {
            throw C07DataExchangeError.invalidManifest("fontSnapshotReferences")
        }
        let index = Dictionary(uniqueKeysWithValues: parsed.fonts.map { ($0.id + ".ttf", $0) })
        for item in items where item.record.logicalPath != "catalog.json" {
            guard let entry = index[item.record.logicalPath], entry.id == item.record.sha256,
                  entry.bytes == item.record.byteCount else {
                throw C07DataExchangeError.invalidManifest("fontSnapshotIdentity")
            }
        }
        if alreadyPrepared {
            let reply = try await request(context: context, method: "snapshot.status", exchangeID: restoreID)
            let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
            guard object?["count"] as? Int == parsed.fonts.count,
                  object?["sourceSHA256"] as? String == manifest.record.sha256 else {
                throw C07DataExchangeError.invalidManifest("fontPreparedIdentity")
            }
            return parsed.fonts.count
        }
        let directory = filesRoot(context).appendingPathComponent("FontRestoreIncomingV1/" + restoreID.uuidString.lowercased())
        var created = false
        defer { if created { try? FileManager.default.removeItem(at: directory) } }
        try C07RootedFileIO.withExclusiveDirectory(at: directory) { owned in
            created = true
            for item in items {
                _ = try C07RootedFileIO.copyFile(sourceRoot: item.url.deletingLastPathComponent(),
                    sourceRelativePath: item.url.lastPathComponent, destinationRoot: directory,
                    destinationRelativePath: item.record.logicalPath, expectedSize: item.record.byteCount,
                    maximum: 32 * 1024 * 1024, destinationDirectory: owned)
            }
        }
        let response = try await request(context: context, method: "snapshot.prepare", exchangeID: restoreID,
                                         catalogSHA256: manifest.record.sha256)
        let object = try JSONSerialization.jsonObject(with: response) as? [String: Any]
        guard object?["count"] as? Int == parsed.fonts.count else {
            throw C07DataExchangeError.invalidManifest("fontPrepareReceipt")
        }
        return parsed.fonts.count
    }
    static func finalize(context: C07DataExchangeContext, plan: C07OwnedDataRestorePlanFile) async throws {
        guard let count = plan.managedFontCount else { return }
        guard count >= 0, count <= 256 else { throw C07DataExchangeError.invalidManifest("fontRestoreCount") }
        let result = try await request(context: context, method: "snapshot.adopt", exchangeID: plan.restoreID)
        let object = try JSONSerialization.jsonObject(with: result) as? [String: Any]
        guard object?["count"] as? Int == count else { throw C07DataExchangeError.invalidManifest("fontAdoptReceipt") }
    }
    static func complete(context: C07DataExchangeContext, restoreID: UUID) async throws {
        _ = try await request(context: context, method: "snapshot.complete", exchangeID: restoreID)
    }
    static func rollback(context: C07DataExchangeContext, plan: C07OwnedDataRestorePlanFile) async throws {
        guard plan.managedFontCount != nil else { return }
        // Rollback is owned recovery, not a replay of a cancelled mutation.
        try await Task.detached {
            _ = try await request(context: context, method: "snapshot.rollback", exchangeID: plan.restoreID, allowMissing: plan.managedFontCount == 0)
        }.value
    }
}
