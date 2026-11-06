// SPDX-License-Identifier: MPL-2.0
import Foundation
import simd

public enum ManufacturingArchive {
    private struct Envelope: Codable {
        var formatVersion: Int
        var study: ManufacturingStudy
        var artifact: ManufacturingArtifact
        var artifactSHA256: String
    }
    public static func save(study: ManufacturingStudy, artifact: ManufacturingArtifact, to url: URL) throws {
        try study.validate()
        guard artifact.studyID == study.id, artifact.inputSHA256 == (try study.fingerprint()) else { throw ManufacturingError.stale }
        guard artifact.startingStockSHA256 == nil else { throw ManufacturingError.archive("continued jobs must be saved in their complete cell archive") }
        try artifact.result.validate(for: study)
        let body = try ManufacturingStudy.encoder.encode(artifact)
        let envelope = Envelope(formatVersion:1,study:study,artifact:artifact,artifactSHA256:ManufacturingStudy.digest(body))
        let data = try ManufacturingStudy.encoder.encode(envelope)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try data.write(to:url,options:.atomic)
    }
    public static func open(_ url: URL) throws -> (ManufacturingStudy,ManufacturingArtifact) {
        let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max
        guard size <= 64_000_000 else { throw ManufacturingError.archive("file budget") }
        let data = try Data(contentsOf:url)
        let envelope = try JSONDecoder().decode(Envelope.self,from:data)
        guard envelope.formatVersion == 1 else { throw ManufacturingError.archive("unsupported version; original bytes retained") }
        try envelope.study.validate()
        let artifact = envelope.artifact
        guard artifact.startingStockSHA256 == nil, artifact.studyID == envelope.study.id,
              artifact.inputSHA256 == (try envelope.study.fingerprint()),
              envelope.artifactSHA256 == ManufacturingStudy.digest(try ManufacturingStudy.encoder.encode(artifact)) else { throw ManufacturingError.archive("source/result digest mismatch") }
        try artifact.result.validate(for:envelope.study)
        return (envelope.study,artifact)
    }
    public static func stl(_ result: ManufacturingResult) throws -> Data {
        guard result.triangles.count <= 180_000 else { throw ManufacturingError.archive("mesh budget") }
        var data = Data("Floe native manufacturing prototype; sampled stock".utf8)
        data.append(Data(repeating:0,count:max(0,80-data.count)))
        func append<T>(_ value: T) { var v = value; withUnsafeBytes(of:&v) { data.append(contentsOf:$0) } }
        append(UInt32(result.triangles.count).littleEndian)
        for triangle in result.triangles {
            guard triangle.count == 3, triangle.allSatisfy({ result.vertices.indices.contains($0) }) else { throw ManufacturingError.archive("mesh indices") }
            let points = try triangle.map { index -> SIMD3<Float> in
                let p = result.vertices[index]
                guard p.count == 3, p.allSatisfy({ $0.isFinite && abs($0) < 100_000 }) else { throw ManufacturingError.archive("mesh coordinate") }
                return SIMD3(Float(p[0]),Float(p[1]),Float(p[2]))
            }
            let raw = simd_cross(points[1]-points[0],points[2]-points[0])
            guard simd_length_squared(raw) > 1e-16 else { throw ManufacturingError.archive("degenerate STL face") }
            for p in [simd_normalize(raw)]+points { for value in [p.x,p.y,p.z] { append(value.bitPattern.littleEndian) } }
            append(UInt16(0))
        }
        return data
    }
    public static func toolpath(_ result: ManufacturingResult) throws -> Data {
        guard let timeline = result.cuttingTimeline else { return try ManufacturingStudy.encoder.encode(result.paths) }
        struct TimedPaths: Encodable {
            let formatVersion = 2
            let units = "mm, seconds, rpm, mm/min"
            let scope: String
            let paths: [ManufacturingResult.Path]
            let cuttingTimeline: CuttingTimeline
        }
        return try ManufacturingStudy.encoder.encode(TimedPaths(scope:timeline.formatVersion == 2 ? "explicit linear motion and dwell; excludes missing links, acceleration, spindle transients, tool changes and rotary-axis time" : "nominal linear cutting paths; no rapid links, acceleration, spindle transients, tool changes or A/C time",paths:result.paths,cuttingTimeline:timeline))
    }
}
