// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Persistent, source-bound 3D model reference stored with the footprint
/// definition. It is metadata only: model bytes are downloaded lazily and
/// verified against these fixed source identities before rendering.
///
/// The transform follows the normalized publisher record:
/// * `offsetMillimetres` is the modern KiCad source offset in mm;
/// * `rotationDegrees` is the authored XYZ rotation in degrees;
/// * `scale` is the authored per-axis scale.
///
/// Legacy inches-based model offsets are not silently reinterpreted; the
/// converter marks them in the retained original and rendering reports the
/// unsupported reference instead of guessing.
public struct EDAFootprintModelReference: Codable, Hashable, Sendable, Identifiable {
    public var modelID: String?
    public var sourceID: String?
    public var sourcePath: String
    public var fileName: String
    public var format: String
    public var repository: String?
    public var revision: String?
    public var gitBlobSHA1: String?
    public var sha256: String?
    public var byteCount: Int?
    public var offsetMillimetres: [Double]?
    public var rotationDegrees: [Double]?
    public var scale: [Double]?
    public var licenseSourceID: String?
    public var licenseAttribution: String?

    public init(modelID: String? = nil, sourceID: String? = nil, sourcePath: String,
                fileName: String, format: String, repository: String? = nil, revision: String? = nil,
                gitBlobSHA1: String? = nil, sha256: String? = nil, byteCount: Int? = nil,
                offsetMillimetres: [Double]? = nil, rotationDegrees: [Double]? = nil,
                scale: [Double]? = nil, licenseSourceID: String? = nil,
                licenseAttribution: String? = nil) {
        self.modelID = modelID; self.sourceID = sourceID; self.sourcePath = sourcePath
        self.fileName = fileName; self.format = format; self.repository = repository
        self.revision = revision; self.gitBlobSHA1 = gitBlobSHA1; self.sha256 = sha256
        self.byteCount = byteCount; self.offsetMillimetres = offsetMillimetres
        self.rotationDegrees = rotationDegrees; self.scale = scale
        self.licenseSourceID = licenseSourceID; self.licenseAttribution = licenseAttribution
    }

    public var id: String { modelID ?? (sourceID ?? "") + ":" + sourcePath }

    /// Same source identity is rendered once and shared across placements.
    public var renderKey: String {
        if let gitBlobSHA1, let modelID { return modelID + ":" + gitBlobSHA1 }
        return sourceID.orEmpty + ":" + sourcePath + ":" + format
    }

    public var isExactRenderable: Bool {
        ["step", "stp", "iges", "igs"].contains(format.lowercased())
    }

    public func validate() throws {
        guard !sourcePath.isEmpty, sourcePath.utf8.count <= 4_096,
              !fileName.isEmpty, fileName == (fileName as NSString).lastPathComponent,
              !fileName.contains("\\"), fileName.utf8.count <= 255,
              !format.isEmpty, format.utf8.count <= 16,
              sourcePath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              [offsetMillimetres, rotationDegrees, scale].allSatisfy({ value in
                  value.map { $0.count == 3 && $0.allSatisfy(\.isFinite) } ?? true
              }) else { throw EDAError.invalid("footprint model reference") }
        if let gitBlobSHA1 {
            guard EDALibraryDigest.validSHA1(gitBlobSHA1) else { throw EDAError.invalid("footprint model Git object") }
        }
        if let sha256 { guard EDALibraryDigest.validSHA256(sha256) else { throw EDAError.invalid("footprint model digest") } }
        if let byteCount { guard (1...ElectronicsRemoteLimits.modelBytes).contains(byteCount) else {
            throw EDAError.invalid("footprint model size")
        } }
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
