// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import Darwin
import FloeIPMMDB

/// Read-only native handles are retained by each worker's snapshot. Replacing
/// the actor's current snapshot cannot close a reader still used by a query.
final class IPMappedDatabase: @unchecked Sendable {
    private let pointer: OpaquePointer
    let metadata: IPDatabaseFileMetadata
    init(file: URL, kind: Int32, expectedHash: String, expected: IPDatabaseFileMetadata? = nil) throws {
        let bytes = try IPDatabaseStorage.regularFileSize(file, maximum: IPDatabaseStorage.maximumDatabaseBytes)
        var info = FloeIPDatabaseMetadata(), error: Int32 = 0
        guard let pointer = floe_ip_open(file.path, kind, IPDatabaseStorage.maximumDatabaseBytes, &info, &error) else { throw IPInformationError.invalidDatabase }
        do {
            let type = try copiedString(&info.type) ?? ""
            let metadata = IPDatabaseFileMetadata(sha256: expectedHash, bytes: bytes, databaseType: type,
                buildEpoch: info.build_epoch, ipVersion: info.ip_version)
            if let expected, expected != metadata { throw IPInformationError.invalidDatabase }
            self.metadata = metadata; self.pointer = pointer
        } catch { floe_ip_close(pointer); throw error }
    }
    deinit { floe_ip_close(pointer) }
    func validateImport() throws {
        let result = floe_ip_validate(pointer, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
        if result == -4 { throw CancellationError() }
        guard result == 0 else { throw result == -3 ? IPInformationError.tooLarge : IPInformationError.invalidDatabase }
    }
    func read(_ address: String, language: String) throws -> FloeIPDatabaseRecord {
        var record = FloeIPDatabaseRecord()
        guard floe_ip_lookup(pointer, address, language, &record) == 0 else { throw IPInformationError.invalidDatabase }
        return record
    }
}

private func copiedString<T>(_ value: inout T) throws -> String? {
    try withUnsafeBytes(of: &value) { bytes in
        let data = bytes.prefix(while: { $0 != 0 })
        guard let text = String(bytes: data, encoding: .utf8) else { throw IPInformationError.invalidDatabase }
        return text.isEmpty ? nil : text
    }
}

final class IPDatabaseSnapshot: @unchecked Sendable {
    let directory: URL
    let metadata: IPDatabaseMetadata
    private let city: IPMappedDatabase
    private let asn: IPMappedDatabase
    init(directory: URL, metadata: IPDatabaseMetadata) throws {
        self.directory = directory; self.metadata = metadata
        city = try IPMappedDatabase(file: directory.appendingPathComponent("city.mmdb"), kind: 1,
            expectedHash: metadata.city.sha256, expected: metadata.city)
        asn = try IPMappedDatabase(file: directory.appendingPathComponent("asn.mmdb"), kind: 2,
            expectedHash: metadata.asn.sha256, expected: metadata.asn)
    }
    func read(_ address: String, language: String) throws -> IPInformationRecord? {
        var c = try city.read(address, language: language), a = try asn.read(address, language: language)
        let code = try copiedString(&c.country_code), country = try copiedString(&c.country)
        let region = try copiedString(&c.region), name = try copiedString(&c.city)
        let organization = try copiedString(&a.organization)
        let number = a.has_asn != 0 ? a.asn : nil
        guard code != nil || country != nil || region != nil || name != nil || organization != nil || number != nil
                || c.has_location != 0 else { return nil }
        return IPInformationRecord(address: address, countryCode: code, country: country, region: region, city: name,
            autonomousSystemNumber: number, organization: organization,
            networkPrefixLength: a.found != 0 ? Int(a.prefix_length) : (c.found != 0 ? Int(c.prefix_length) : nil),
            source: metadata.source, datasetVersion: metadata.datasetVersion,
            latitude: c.has_location != 0 ? c.latitude : nil,
            longitude: c.has_location != 0 ? c.longitude : nil,
            accuracyRadiusKilometers: c.has_accuracy_radius != 0 ? c.accuracy_radius_kilometers : nil)
    }
}

enum IPDatabaseStorage {
    static let maximumDatabaseBytes: UInt64 = 512 * 1_024 * 1_024
    struct Pointer: Codable { let current: UUID; let previous: UUID? }
    static func prepareRoot(_ supplied: URL) throws -> URL {
        guard supplied.isFileURL, supplied.path.hasPrefix("/"), supplied.path != "/" else { throw IPInformationError.invalidStorage }
        let root = supplied.resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["Snapshots", "Staging", "Downloads"] {
            let child = root.appendingPathComponent(name, isDirectory: true)
            if !FileManager.default.fileExists(atPath: child.path) {
                do { try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false) }
                catch {
                    // Another initializer may have made this same directory.
                    guard FileManager.default.fileExists(atPath: child.path) else { throw IPInformationError.invalidStorage }
                }
            }
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw IPInformationError.invalidStorage }
        }
        return root
    }
    static func regularFileSize(_ url: URL, maximum: UInt64) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0 else { throw IPInformationError.invalidDatabase }
        guard UInt64(size) <= maximum else { throw IPInformationError.tooLarge }
        return UInt64(size)
    }
    static func digest(_ url: URL, maximum: UInt64) throws -> String {
        _ = try regularFileSize(url, maximum: maximum)
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var value = SHA256(), total: UInt64 = 0
        while let bytes = try file.read(upToCount: 128 * 1_024), !bytes.isEmpty {
            try Task.checkCancellation(); total += UInt64(bytes.count)
            guard total <= maximum else { throw IPInformationError.tooLarge }
            value.update(data: bytes)
        }
        return value.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func copy(_ source: URL, to destination: URL) throws -> String {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        _ = try regularFileSize(source, maximum: maximumDatabaseBytes)
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw IPInformationError.invalidStorage }
        let output = try FileHandle(forWritingTo: destination); defer { try? output.close() }
        var value = SHA256(), size: UInt64 = 0
        while let data = try input.read(upToCount: 128 * 1_024), !data.isEmpty {
            try Task.checkCancellation(); size += UInt64(data.count)
            guard size <= maximumDatabaseBytes else { throw IPInformationError.tooLarge }
            try output.write(contentsOf: data); value.update(data: data)
        }
        try output.synchronize()
        return value.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func expand(_ archive: URL, to destination: URL) throws {
        let result = floe_ip_expand_gzip(archive.path, destination.path, maximumDatabaseBytes,
            { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
        if result == -4 { throw CancellationError() }
        guard result == 0 else { throw result == -3 ? IPInformationError.tooLarge : IPInformationError.invalidDownload }
    }
    static func load(_ root: URL) throws -> IPDatabaseSnapshot? {
        guard let pointer = try pointer(root) else { return nil }
        let directory = root.appendingPathComponent("Snapshots/" + pointer.current.uuidString, isDirectory: true)
        let directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else { throw IPInformationError.invalidStorage }
        let manifest = directory.appendingPathComponent("manifest.json")
        _ = try regularFileSize(manifest, maximum: 32 * 1_024)
        let metadata = try JSONDecoder().decode(IPDatabaseMetadata.self, from: Data(contentsOf: manifest))
        guard metadata.id == pointer.current, !metadata.datasetVersion.isEmpty,
              metadata.datasetVersion.utf8.count <= 256, IPDatabaseRelease.validHash(metadata.city.sha256),
              IPDatabaseRelease.validHash(metadata.asn.sha256) else { throw IPInformationError.invalidDatabase }
        guard try digest(directory.appendingPathComponent("city.mmdb"), maximum: maximumDatabaseBytes) == metadata.city.sha256,
              try digest(directory.appendingPathComponent("asn.mmdb"), maximum: maximumDatabaseBytes) == metadata.asn.sha256 else { throw IPInformationError.checksumMismatch }
        return try IPDatabaseSnapshot(directory: directory, metadata: metadata)
    }
    static func pointer(_ root: URL) throws -> Pointer? {
        let url = root.appendingPathComponent("CURRENT.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        _ = try regularFileSize(url, maximum: 4 * 1_024)
        return try JSONDecoder().decode(Pointer.self, from: Data(contentsOf: url))
    }
    static func commit(_ snapshot: IPDatabaseSnapshot, root: URL, expected: UUID?) throws {
        let descriptor = open(root.appendingPathComponent("update.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw IPInformationError.invalidStorage }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw IPInformationError.invalidStorage }
        guard try pointer(root)?.current == expected else { throw IPInformationError.versionChanged }
        try Task.checkCancellation()
        let target = root.appendingPathComponent("CURRENT.json")
        let stage = root.appendingPathComponent(".current-" + snapshot.metadata.id.uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        try durableWrite(try JSONEncoder().encode(Pointer(current: snapshot.metadata.id, previous: expected)), to: stage)
        guard rename(stage.path, target.path) == 0 else { throw IPInformationError.invalidStorage }
    }
    static func durableWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .withoutOverwriting)
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        try file.synchronize()
    }
    static func retireUnused(root: URL, snapshots: Set<UUID>, archives: Set<String>?) throws {
        for directory in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Snapshots"), includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: directory.lastPathComponent), !snapshots.contains(id),
                  let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let manifest = directory.appendingPathComponent("manifest.json")
            guard (try? regularFileSize(manifest, maximum: 32 * 1_024)) != nil,
                  let bytes = try? Data(contentsOf: manifest),
                  let metadata = try? JSONDecoder().decode(IPDatabaseMetadata.self, from: bytes), metadata.id == id,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
                  Set(names) == Set(["city.mmdb", "asn.mmdb", "manifest.json"]),
                  (try? regularFileSize(directory.appendingPathComponent("city.mmdb"), maximum: maximumDatabaseBytes)) != nil,
                  (try? regularFileSize(directory.appendingPathComponent("asn.mmdb"), maximum: maximumDatabaseBytes)) != nil else { continue }
            // Only an old managed copy retires. User-picked originals are
            // never here; current, rollback and every actual reader lease stay.
            try FileManager.default.removeItem(at: directory)
        }
        if let archives {
            for file in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Downloads"), includingPropertiesForKeys: nil) {
                try Task.checkCancellation()
                let hash = file.deletingPathExtension().lastPathComponent
                guard file.pathExtension == "gz", IPDatabaseRelease.validHash(hash), !archives.contains(hash),
                      (try? digest(file, maximum: 128 * 1_024 * 1_024)) == hash else { continue }
                try FileManager.default.removeItem(at: file)
            }
        }
    }
    static func preparePair(directory: URL, label: String, source: String, attribution: String,
                            licenseURL: URL?, cityHash: String, asnHash: String,
                            month: String? = nil, validateImport: Bool = true) throws -> IPDatabaseSnapshot {
        let city = try IPMappedDatabase(file: directory.appendingPathComponent("city.mmdb"), kind: 1, expectedHash: cityHash)
        let asn = try IPMappedDatabase(file: directory.appendingPathComponent("asn.mmdb"), kind: 2, expectedHash: asnHash)
        if validateImport { try city.validateImport(); try asn.validateImport() }
        if let month {
            let format = DateFormatter(); format.calendar = Calendar(identifier: .gregorian)
            format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0); format.dateFormat = "yyyy-MM"
            guard [city.metadata, asn.metadata].allSatisfy({ format.string(from: Date(timeIntervalSince1970: Double($0.buildEpoch))) == month }) else { throw IPInformationError.invalidDatabase }
        }
        guard let identifier = UUID(uuidString: directory.lastPathComponent) else { throw IPInformationError.invalidStorage }
        let metadata = IPDatabaseMetadata(id: identifier,
            datasetVersion: label + "-" + cityHash + "-" + asnHash, releaseLabel: label, source: source,
            attribution: attribution, licenseURL: licenseURL, installedAt: Date(), city: city.metadata, asn: asn.metadata)
        try durableWrite(try JSONEncoder().encode(metadata), to: directory.appendingPathComponent("manifest.json"))
        for name in ["city.mmdb", "asn.mmdb", "manifest.json"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: directory.appendingPathComponent(name).path)
        }
        return try IPDatabaseSnapshot(directory: directory, metadata: metadata)
    }
}
