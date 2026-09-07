import Foundation
import Crypto

/// Immutable bytes, not a path that can be changed after an approval check.
public struct SkillContentSnapshot: Sendable {
    public let package: ValidatedSkillPackage
    public let files: [String: Data]

    public init(root: URL, expectedDigest: String) throws {
        let package = try SkillPackageValidator().validate(packageAt: root)
        guard package.canonicalSHA256 == expectedDigest else { throw SkillValidationError.digestMismatch }
        var files: [String: Data] = [:]
        var hasher = SHA256()
        for file in package.files {
            let path = Data(file.relativePath.utf8)
            var length = UInt64(path.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
            hasher.update(data: path)
            let bytes = try Data(contentsOf: root.appendingPathComponent(file.relativePath))
            var size = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &size) { hasher.update(data: Data($0)) }
            hasher.update(data: bytes)
            files[file.relativePath] = bytes
        }
        guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == expectedDigest else {
            throw SkillValidationError.digestMismatch
        }
        self.package = package
        self.files = files
    }
}
