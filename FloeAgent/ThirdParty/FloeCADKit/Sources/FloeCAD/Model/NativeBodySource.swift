import Foundation
import CryptoKit
import simd

/// One immutable source for a previously non-parametric exact body. The live
/// body is a rebuild result; it must never become its own next replay input.
/// Captured once before the first edit, not once per downstream operation.
nonisolated struct NativeBodySource: Codable, Sendable {
    static let supportedVersion = 1
    let version: Int
    let name: String
    private(set) var placement: Transform3D
    let sha256: String
    private let brepData: Data
    private let faces: [FaceWitness]
    /// Derived once, not stored in the package. A different witness must not
    /// hit the old memo even when the immutable geometry bytes are identical.
    let faceWitnessSHA256: String
    var byteCount: Int { brepData.count }

    nonisolated struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
    private nonisolated struct FaceWitness: Codable, Sendable {
        let index: Int
        let signature: FaceSignature?
    }

    init(capturing body: Body) throws {
        guard let handle = body.brep, handle.containsSolid,
              let independent = OCCTKernel.independentSnapshot(handle),
              let data = OCCTKernel.serialize(independent), !data.isEmpty else {
            throw Failure(message: "The original exact body could not be preserved for replay.")
        }
        version = Self.supportedVersion
        name = body.name
        placement = body.transform
        brepData = data
        sha256 = Self.digest(data)
        faces = OCCTKernel.faceInfo(independent).map { .init(index: $0.index, signature: $0.signature) }
        faceWitnessSHA256 = try Self.witnessDigest(faces)
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case version, name, placement, sha256, brepData, faces
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version == Self.supportedVersion else {
            throw Failure(message: "Unsupported exact body source version \(version).")
        }
        name = try c.decode(String.self, forKey: .name)
        placement = try c.decode(Transform3D.self, forKey: .placement)
        sha256 = try c.decode(String.self, forKey: .sha256)
        brepData = try c.decode(Data.self, forKey: .brepData)
        faces = try c.decode([FaceWitness].self, forKey: .faces)
        faceWitnessSHA256 = try Self.witnessDigest(faces)
        try validate()
        guard Self.digest(brepData) == sha256 else {
            throw Failure(message: "The saved exact body source failed its integrity check.")
        }
    }

    private func validate() throws {
        let frame = placement.rotation.vector
        guard version == Self.supportedVersion, !brepData.isEmpty, sha256.count == 64,
              placement.scale.isFinite, placement.scale > 0,
              [placement.translation.x, placement.translation.y, placement.translation.z,
               frame.x, frame.y, frame.z, frame.w].allSatisfy(\.isFinite),
              abs(simd_length(frame) - 1) < 1e-6,
              !faces.isEmpty, Set(faces.map(\.index)).count == faces.count,
              faces.allSatisfy({ $0.index > 0 }) else {
            throw Failure(message: "The saved exact body source is invalid.")
        }
    }

    /// Map a new selection to the verified readback of this immutable blob.
    /// The live body's face ordinal is never assumed to survive copying/read.
    func names(forCurrentFaces indices: [Int], on body: Body, creator: FeatureID) throws -> [Int: ElementName] {
        if indices.isEmpty { return [:] }
        guard let names = CADFaceNamingSnapshot.namesForImmutableArchive(body: body, archive: brepData,
            creator: creator, indices: Set(indices), existing: [:]),
              indices.allSatisfy({ names[$0]?.isStableFaceIdentity == true }) else {
            throw Failure(message: "The selected faces could not be preserved in the original exact source.")
        }
        return names
    }

    func translated(by offset: SIMD3<Double>) -> Self {
        var copy = self
        copy.placement.translation += offset
        return copy
    }

    func restoredBody(id: BodyID, revision: UInt64) throws -> Body {
        try validate()
        guard let handle = OCCTKernel.deserialize(brepData), handle.containsSolid else {
            throw Failure(message: "The original exact body could not be restored.")
        }
        let actual = OCCTKernel.faceInfo(handle)
        guard actual.count == faces.count, zip(actual, faces).allSatisfy({ current, saved in
            current.index == saved.index && Self.matches(current.signature, saved.signature)
        }) else {
            throw Failure(message: "The original face identities changed while restoring the exact body.")
        }
        var body = Body(id: id, name: name, transform: placement, primitive: nil,
            render: RenderMesh(positions: [], normals: [], indices: []), revision: revision)
        guard body.adoptBRep(handle) else {
            throw Failure(message: "The original exact body could not be displayed.")
        }
        return body
    }

    /// This is a readback of the SAME digest-bound immutable source, never a
    /// search for a replacement. Numerical integration can round on BRep read;
    /// any index/type/geometry disagreement rejects the complete restoration.
    private static func matches(_ lhs: FaceSignature?, _ rhs: FaceSignature?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        func close(_ a: Double, _ b: Double) -> Bool {
            a.isFinite && b.isFinite && abs(a - b) <= 1e-8 * max(1, abs(a), abs(b))
        }
        switch (lhs.kind, rhs.kind) {
        case (.planar, .planar): break
        case let (.cylindrical(a), .cylindrical(b)): guard close(a, b) else { return false }
        default: return false
        }
        return zip([lhs.normal.x, lhs.normal.y, lhs.normal.z, lhs.centroid.x,
                    lhs.centroid.y, lhs.centroid.z, lhs.area, lhs.planeOffset],
                   [rhs.normal.x, rhs.normal.y, rhs.normal.z, rhs.centroid.x,
                    rhs.centroid.y, rhs.centroid.z, rhs.area, rhs.planeOffset]).allSatisfy { close($0.0, $0.1) }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func witnessDigest(_ faces: [FaceWitness]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return digest(try encoder.encode(faces))
    }
}
