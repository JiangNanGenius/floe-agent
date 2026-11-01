// SPDX-License-Identifier: MPL-2.0
//
// C04C native `.floecad` DIRECTORY package contract.
//
// This is a pure, path-free reference parser for the ACTUAL FloeCADKit store
// written by `FileCADDocumentStore.swift` (fixed donor object
// a59b4d4005f616c611df67fab7620e9853c525b9). It is deliberately not the
// intermediate `floe.cad-package/1` metadata schema from C04A: a native
// package is a directory with manifest.json, document.json and blobs.
//
// The Android byte reader is C04FloecadPackage.kt, which stages every member
// through the existing G04 workspace egress. This Swift value layer owns the
// shared identity/limit/path contract and is exercised by synthetic-byte
// tests; it never opens a directory, never resolves a host path and never
// rewrites the package.
import Foundation
import Crypto

public enum C04FloecadPackageLimits {
    public static let packageExtension = "floecad"
    public static let manifestName = "manifest.json"
    public static let documentName = "document.json"
    public static let maximumManifestBytes = 2 * 1024 * 1024
    public static let maximumDocumentBytes = 32 * 1024 * 1024
    public static let maximumBlobBytes = 256 * 1024 * 1024
    public static let maximumPackageBytes = 512 * 1024 * 1024
    public static let maximumBodies = 512
    public static let maximumImages = 128
    public static let maximumAssemblyInstances = 4_096
    public static let maximumMissingResources = 512
    public static let maximumSessionResources = 512
    public static let maximumSessionTotalBytes = C04FloecadPackageLimits.maximumPackageBytes
    public static let maximumPathBytes = 4_096
    public static let maximumNameCharacters = 256
    /// The native FloeCAD writer and OS3D/OCCT payloads are millimetres.
    /// glTF 2.0 has no unit field: its normative scene unit is the metre, so
    /// the derived preview converts every position/translation by this scale
    /// instead of relabelling millimetre numbers as metres.
    public static let sourceUnit = "mm"
    public static let gltfUnit = "m"
    public static let sourceUnitScaleToMeters = 0.001
    public static let maximumBrepConversionBytes = 10 * 1024 * 1024
    public static let resourceExtensions: Set<String> = [
        "json", "mesh", "brep", "img", "png", "jpg", "jpeg", "webp",
    ]
    public static let blobExtensions: Set<String> = ["mesh", "brep", "img"]
    public static let imageMediaTypes: Set<String> = [
        "image/png", "image/jpeg", "image/webp",
    ]
}

public enum C04FloecadPackage {
    public struct Manifest: Sendable, Equatable {
        public let schemaVersion: Int
        public let revision: Int
        public let name: String
        public let contentSHA256: String
        public let modelSHA256: String?
        public let thumbnailSHA256: String?
        public let unit: String
        public let tolerance: Double?
    }

    public struct DocumentHeader: Sendable, Equatable {
        public let bodyCount: Int
        public let imageCount: Int
        public let hasAssembly: Bool
        public let hasDrawings: Bool
    }

    public struct MeshHeader: Sendable, Equatable {
        public let magic: UInt32
        public let version: UInt32
        public let vertexCount: Int
        public let indexCount: Int
        public let byteCount: Int
    }

    public enum Failure: Error, Equatable {
        case invalid(String)
        case unsupported(String)
    }

    /// Strict native-manifest parser. Unknown keys are ignored so a newer
    /// schema opens read-only; malformed required identities fail closed.
    public static func parseManifest(_ data: Data) throws -> Manifest {
        guard data.count in 1...C04FloecadPackageLimits.maximumManifestBytes,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let schema = c04Int(object["schemaVersion"]), schema >= 1, schema <= 1_000,
              let revision = c04Int(object["revision"]), revision >= 0,
              let name = c04String(object["name"], maxBytes: C04FloecadPackageLimits.maximumNameCharacters),
              let content = c04String(object["contentSHA256"], maxBytes: 64),
              C04CadHex.isSHA256(content) else {
            throw Failure.invalid("manifest")
        }
        let model = c04String(object["modelSHA256"], maxBytes: 64)
        if object["modelSHA256"] != nil, model == nil || !C04CadHex.isSHA256(model!) {
            throw Failure.invalid("modelSHA256")
        }
        let thumbnail = c04String(object["thumbnailSHA256"], maxBytes: 64)
        if object["thumbnailSHA256"] != nil, thumbnail == nil || !C04CadHex.isSHA256(thumbnail!) {
            throw Failure.invalid("thumbnailSHA256")
        }
        let rawUnit = c04String(object["unit"], maxBytes: 8) ?? "mm"
        guard ["mm", "cm", "m", "in", "ft"].contains(rawUnit) else {
            throw Failure.invalid("unit")
        }
        let tolerance = c04Double(object["tolerance"])
        if object["tolerance"] != nil,
           tolerance == nil || !tolerance!.isFinite || tolerance! < 0 || tolerance! > 1e9 {
            throw Failure.invalid("tolerance")
        }
        return Manifest(
            schemaVersion: schema, revision: revision, name: name,
            contentSHA256: content.lowercased(),
            modelSHA256: model?.lowercased(),
            thumbnailSHA256: thumbnail?.lowercased(),
            unit: rawUnit, tolerance: tolerance)
    }

    public static func parseDocumentHeader(_ data: Data) throws -> DocumentHeader {
        guard data.count in 1...C04FloecadPackageLimits.maximumDocumentBytes,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let bodies = object["bodies"] as? [Any],
              bodies.count <= C04FloecadPackageLimits.maximumBodies else {
            throw Failure.invalid("document")
        }
        let images = (object["images"] as? [Any]) ?? []
        guard images.count <= C04FloecadPackageLimits.maximumImages else {
            throw Failure.invalid("images")
        }
        return DocumentHeader(
            bodyCount: bodies.count,
            imageCount: images.count,
            hasAssembly: object["assembly"] != nil,
            hasDrawings: object["drawings"] != nil)
    }

    /// Exact writer identity: document bytes, every blob path + digest in
    /// sorted order, then the optional preview digest (no thumbnail path).
    public static func contentSHA256(documentBytes: Data,
                                    blobs: [(path: String, sha256: String)],
                                    thumbnailSHA256: String?) throws -> String {
        guard !documentBytes.isEmpty else { throw Failure.invalid("document") }
        var hasher = SHA256()
        hasher.update(data: documentBytes)
        for blob in blobs.sorted(by: { $0.path < $1.path }) {
            guard validateBlobPath(blob.path) else { throw Failure.invalid("blobPath") }
            guard C04CadHex.isSHA256(blob.sha256) else { throw Failure.invalid("blobDigest") }
            hasher.update(data: Data(blob.path.utf8))
            hasher.update(data: Data(blob.sha256.lowercased().utf8))
        }
        if let thumbnailSHA256, !thumbnailSHA256.isEmpty {
            guard C04CadHex.isSHA256(thumbnailSHA256) else { throw Failure.invalid("thumbnailSHA256") }
            hasher.update(data: Data(thumbnailSHA256.lowercased().utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Canonical package-relative blob path: `blobs/<file>` or
    /// `blobs/images/<file>`, no absolute/URI/traversal/backslash component.
    public static func validateBlobPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= C04FloecadPackageLimits.maximumPathBytes,
              !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            return false
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3, parts[0] == "blobs" else { return false }
        if parts.count == 3, parts[1] != "images" { return false }
        for part in parts {
            guard !part.isEmpty, part != ".", part != "..", part.utf8.count <= 255 else { return false }
        }
        let ext = path.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
        return C04FloecadPackageLimits.blobExtensions.contains(ext)
    }

    /// OS3D v1/v2 header + exact length proof. Indices are still validated by
    /// the byte reader; this is the shared structural contract.
    public static func parseMeshHeader(_ data: Data) throws -> MeshHeader {
        guard data.count >= 16 else { throw Failure.invalid("meshTruncated") }
        func uint32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }.littleEndian
        }
        let magic = uint32(0)
        guard magic == 0x4F533344 else { throw Failure.invalid("meshMagic") }
        let version = uint32(4)
        guard version == 1 || version == 2 else { throw Failure.unsupported("meshVersion") }
        let vertices = Int(uint32(8))
        let indices = Int(uint32(12))
        guard vertices >= 0, indices >= 0,
              vertices <= 4_000_000, indices <= 12_000_000,
              indices > 0, indices % 3 == 0 else {
            throw Failure.invalid("meshCounts")
        }
        let expected = 16 + vertices * 24 + indices * 4 + (version == 2 ? vertices * 8 : 0)
        guard expected == data.count else {
            throw Failure.invalid(expected > data.count ? "meshTruncated" : "meshLength")
        }
        return MeshHeader(
            magic: magic, version: version, vertexCount: vertices,
            indexCount: indices, byteCount: expected)
    }
}
