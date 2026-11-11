// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum IPInformationError: Error, LocalizedError, Sendable, Equatable {
    case invalidAddress, invalidStorage, invalidDatabase, invalidDownload, checksumMismatch
    case tooLarge, timedOut, versionChanged, busy, missingOperation, unavailable
    public var errorDescription: String? {
        let zh = Locale.current.language.languageCode?.identifier == "zh"
        switch self {
        case .invalidAddress: return zh ? "请输入有效的 IP 地址。" : "Enter a valid IP address."
        case .invalidStorage: return zh ? "无法访问数据库存储位置。" : "The database storage is unavailable."
        case .invalidDatabase: return zh ? "数据库无效或类型不匹配，原数据库已保留。" : "The database is invalid or has the wrong type. The previous database was kept."
        case .invalidDownload, .checksumMismatch: return zh ? "下载校验未通过，原数据库已保留。" : "The download could not be verified. The previous database was kept."
        case .tooLarge: return zh ? "数据库超过大小限制。" : "The database exceeds the size limit."
        case .timedOut: return zh ? "数据库处理超时，原数据库已保留。" : "Database processing timed out. The previous database was kept."
        case .versionChanged: return zh ? "数据库已更新，请重新查询。" : "The database changed. Try the lookup again."
        case .busy: return zh ? "数据库正在处理，请稍后重试。" : "The database is busy. Try again shortly."
        case .missingOperation: return zh ? "找不到此次更新。" : "This update is no longer available."
        case .unavailable: return zh ? "请先下载或导入 IP 数据库。" : "Download or import an IP database first."
        }
    }
}

public struct IPDatabaseFileMetadata: Codable, Sendable, Equatable {
    public let sha256: String
    public let bytes: UInt64
    public let databaseType: String
    public let buildEpoch: UInt64
    public let ipVersion: UInt16
}

public struct IPDatabaseMetadata: Codable, Sendable, Equatable {
    public let id: UUID
    public let datasetVersion: String
    public let releaseLabel: String
    public let source: String
    public let attribution: String
    public let licenseURL: URL?
    public let installedAt: Date
    public let city: IPDatabaseFileMetadata
    public let asn: IPDatabaseFileMetadata
}

public struct IPInformationRecord: Sendable, Equatable {
    public let address: String
    public let countryCode: String?
    public let country: String?
    public let region: String?
    public let city: String?
    public let autonomousSystemNumber: UInt32?
    public let organization: String?
    public let networkPrefixLength: Int?
    public let source: String
    public let datasetVersion: String
    public var regionSummary: String? {
        var seen = Set<String>()
        let values = [country, region, city].compactMap { $0 }.filter { !$0.isEmpty && seen.insert($0).inserted }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }
    func addressed(_ address: String) -> Self {
        Self(address: address, countryCode: countryCode, country: country, region: region, city: city,
             autonomousSystemNumber: autonomousSystemNumber, organization: organization,
             networkPrefixLength: networkPrefixLength, source: source, datasetVersion: datasetVersion)
    }
}

public struct IPInformationState: Sendable, Equatable {
    public enum Phase: String, Sendable { case ready, empty, downloading, validating, installing, cancelled, failed }
    public let phase: Phase
    public let operationID: UUID?
    public let downloadedBytes: Int64
    public let totalBytes: Int64?
    public let metadata: IPDatabaseMetadata?
    public let message: String?
    public var isUpdating: Bool { [.downloading, .validating, .installing].contains(phase) }
}

/// An explicit reviewed monthly pair. Hashes bind both compressed transfer
/// and expanded databases; arbitrary per-IP network lookups do not exist.
public struct IPDatabaseRelease: Sendable {
    public struct Artifact: Sendable {
        public let url: URL
        public let archiveSHA256: String
        public let sha256: String
        public init(url: URL, archiveSHA256: String, sha256: String) {
            self.url = url; self.archiveSHA256 = archiveSHA256; self.sha256 = sha256
        }
    }
    public let month: String
    public let city: Artifact
    public let asn: Artifact
    public init(month: String, city: Artifact, asn: Artifact) {
        self.month = month; self.city = city; self.asn = asn
    }
    public static let dbIPNovember2026 = Self(month: "2026-11",
        city: Artifact(url: URL(string: "https://download.db-ip.com/free/dbip-city-lite-2026-11.mmdb.gz")!,
            archiveSHA256: "b69c625515f636ac92112b71df26bb92a5748f648c79bad124ecd9ba1c97bf4a",
            sha256: "5f64491f77c2c78b56cd83a88db4ea6c4666874322da38805498bbb754ccc735"),
        asn: Artifact(url: URL(string: "https://download.db-ip.com/free/dbip-asn-lite-2026-11.mmdb.gz")!,
            archiveSHA256: "36a8c45136877d8df48ad371de6c9c97c861dedd356277f30de730c16fc0f928",
            sha256: "81565a450281c949fc83745f5ec9cfea70b035163b1152b055645884765d153d"))
    func validate() throws {
        guard month.range(of: #"^20[0-9]{2}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil else { throw IPInformationError.invalidDownload }
        for (kind, item) in [("city", city), ("asn", asn)] {
            guard item.url.scheme == "https", item.url.host == "download.db-ip.com", item.url.user == nil,
                  item.url.password == nil, item.url.query == nil,
                  item.url.path == "/free/dbip-\(kind)-lite-\(month).mmdb.gz",
                  Self.validHash(item.archiveSHA256), Self.validHash(item.sha256) else { throw IPInformationError.invalidDownload }
        }
    }
    static func validHash(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
