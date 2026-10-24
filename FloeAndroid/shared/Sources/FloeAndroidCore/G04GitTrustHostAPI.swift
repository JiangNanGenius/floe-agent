// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGit

/// Trusted-host-only platform CA ingress. There is no workspace command or
/// model tool capable of installing a trust record. Native Git still verifies
/// the exact private file before every remote libgit2 operation.
enum G04GitTrustHostAPI {
    private struct HostRecord: Decodable {
        let bundleID: String
        let bundleFilePath: String
        let privateRootPath: String
        let sha256Hex: String
        let certificateCount: Int
        let byteCount: Int
        let exportedAtUnixMillis: Int64
        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            let expected: Set<String> = ["bundleID", "bundleFilePath", "privateRootPath", "sha256Hex",
                "certificateCount", "byteCount", "exportedAtUnixMillis"]
            guard Set(c.allKeys.map(\.stringValue)) == expected else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid trust record fields"))
            }
            func field<T: Decodable>(_ key: String, _ type: T.Type) throws -> T {
                try c.decode(type, forKey: Key(stringValue: key)!)
            }
            bundleID = try field("bundleID", String.self)
            bundleFilePath = try field("bundleFilePath", String.self)
            privateRootPath = try field("privateRootPath", String.self)
            sha256Hex = try field("sha256Hex", String.self)
            certificateCount = try field("certificateCount", Int.self)
            byteCount = try field("byteCount", Int.self)
            exportedAtUnixMillis = try field("exportedAtUnixMillis", Int64.self)
        }
    }

    private final class Binding: @unchecked Sendable {
        let lock = NSLock()
        var epoch: UInt64?
        var bundleID: String?
        var retiredEpochs: Set<UInt64> = []
    }
    private static let binding = Binding()

    private static func current(_ epoch: UInt64) -> Bool {
        epoch > 0 && G02NativeRootEpoch.readback() == epoch &&
            G02RuntimeComposition.shared.installedComposition?.epoch == epoch
    }

    static func install(epoch: UInt64, data: Data) -> Int32 {
        guard data.count <= 16_384, current(epoch),
              let record = try? JSONDecoder().decode(HostRecord.self, from: data),
              record.bundleID.utf8.count <= 128,
              record.bundleFilePath.utf8.count <= 4096, record.privateRootPath.utf8.count <= 4096,
              record.bundleFilePath.hasPrefix("/"), record.privateRootPath.hasPrefix("/"),
              !record.bundleFilePath.contains("\0"), !record.privateRootPath.contains("\0") else { return -702 }
        return binding.lock.withLock {
            guard current(epoch), !binding.retiredEpochs.contains(epoch) else { return -701 }
            if let old = binding.epoch, old != epoch { return -703 }
            let value = GitTrustedBundleRecord(bundleID: record.bundleID,
                bundleFileURL: URL(fileURLWithPath: record.bundleFilePath), privateRootPath: record.privateRootPath,
                expectedSHA256Hex: record.sha256Hex, expectedCertificateCount: record.certificateCount,
                expectedByteCount: record.byteCount, exportedAtUnixMillis: record.exportedAtUnixMillis)
            do {
                try GitRemoteTrust.shared.install(value)
                guard current(epoch) else {
                    _ = try? GitRemoteTrust.shared.retire(expectedBundleID: record.bundleID)
                    return -701
                }
                binding.epoch = epoch; binding.bundleID = record.bundleID
                return 0
            } catch { return -704 } // No paths, certificate bytes or errors cross this seam.
        }
    }

    @discardableResult
    static func retire(epoch: UInt64) -> Int32 {
        binding.lock.withLock {
            binding.retiredEpochs.insert(epoch)
            if binding.retiredEpochs.count > 64 {
                let live = G02NativeRootEpoch.readback()
                binding.retiredEpochs = binding.retiredEpochs.filter { $0 == live }
            }
            guard let old = binding.epoch else { return 0 }
            guard old == epoch, let id = binding.bundleID else { return -701 }
            do {
                _ = try GitRemoteTrust.shared.retire(expectedBundleID: id)
                binding.epoch = nil; binding.bundleID = nil
                return 0
            } catch { return -704 }
        }
    }
}

@_cdecl("floe_g04_git_trust_install")
public func floeG04GitTrustInstall(_ epoch: UInt64, _ bytes: UnsafePointer<UInt8>?, _ count: Int32) -> Int32 {
    guard count > 0, count <= 16_384, let bytes else { return -702 }
    return G04GitTrustHostAPI.install(epoch: epoch, data: Data(bytes: bytes, count: Int(count)))
}

@_cdecl("floe_g04_git_trust_retire")
public func floeG04GitTrustRetire(_ epoch: UInt64) -> Int32 { G04GitTrustHostAPI.retire(epoch: epoch) }
