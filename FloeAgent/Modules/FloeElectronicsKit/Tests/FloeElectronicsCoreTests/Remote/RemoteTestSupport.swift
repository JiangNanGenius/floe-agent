// SPDX-License-Identifier: MPL-2.0
import Foundation
import zlib
@testable import FloeElectronicsCore

enum RemoteTestSupport {
    static let versionSuffix = "0123456789abcdef0123"
    static let dataset = String(repeating: "ab", count: 32)
    static let producer = String(repeating: "cd", count: 20)
    static let tooling = String(repeating: "ef", count: 32)
    static let sourceCommit = String(repeating: "12", count: 20)
    static let chunkPath = "records/lib-a/00000.jsonl.gz"
    static let indexPath = "indexes/lib-a.jsonl.gz"
    static let realModelPath = "Connector_Phoenix_GMSTB.3dshapes/PhoenixContact_GMSTBA_2,5_10-G-7,62_1x10_P7.62mm_Horizontal.step"

    struct Fixture {
        let releaseData: Data
        let publication: ElectronicsRemotePublication
        let catalogData: Data
        let catalog: ElectronicsRemoteCatalog
        let manifestData: Data
        let manifest: ElectronicsRemoteManifest
        let modelGzip: Data
        let modelBytes: Data
        let model: ElectronicsRemoteModelRecord
        let indexGzip: Data
        let chunkGzip: Data
        let packageBytes: Data
        let fullPackageBytes: Data
        let partRecord: Data
    }

    static func gzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initialized = deflateInit2_(&stream, 9, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                                       ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw ElectronicsRemoteError.integrity("test gzip init") }
        defer { deflateEnd(&stream) }
        let capacity = max(1_024, data.count + 1_024)
        let buffer = UnsafeMutablePointer<Bytef>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        return try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return Data() }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(raw.count)
            stream.next_out = buffer
            stream.avail_out = uInt(capacity)
            let status = deflate(&stream, Z_FINISH)
            guard status == Z_STREAM_END else { throw ElectronicsRemoteError.integrity("test gzip deflate") }
            return Data(bytes: buffer, count: capacity - Int(stream.avail_out))
        }
    }

    static func modelBytes() -> Data {
        Data((0..<512).map { UInt8($0 % 251) })
    }

    static func fixture() throws -> Fixture {
        let modelFile = modelBytes()
        let gitSHA1 = ElectronicsRemoteDigest.gitBlobSHA1(byteCount: modelFile.count, data: modelFile)
        let sha256 = ElectronicsRemoteDigest.sha256(modelFile)
        let package = Data("fake-source-zip".utf8)
        let full = Data("fake-full-zip".utf8)
        let originals = Data("fake-originals-zip".utf8)
        let partRecord = Data(#"{"schemaVersion":1,"id":"floe:electronics:lib-a:symbol:Demo","kind":"symbol","name":"Demo","library":"Demo","status":"converted","units":"mm","source":{"path":"Demo.kicad_sym","sha256":"__SRC__"},"issues":[],"properties":{},"pins":[],"pads":[]}"#
            .replacingOccurrences(of: "__SRC__", with: String(repeating: "34", count: 32)).utf8)
        let partSHA = ElectronicsRemoteDigest.sha256(partRecord + Data([0x0A]))
        let indexGzip2 = try gzip(Data(
            #"{"id":"floe:electronics:lib-a:symbol:Demo","kind":"symbol","name":"Demo","library":"Demo","status":"converted","path":"records/lib-a/00000.jsonl.gz","line":1,"sha256":"__SHA__","sourcePath":"Demo.kicad_sym"}"#
                .replacingOccurrences(of: "__SHA__", with: partSHA).utf8))
        let chunkGzip = try gzip(partRecord + Data([0x0A]))
        let modelRecord = ElectronicsRemoteModelRecord(id: "model:lib-a:" + realModelPath,
            sourceID: "lib-a", repository: "https://github.com/sparkfun/SparkFun-KiCad-Libraries",
            revision: sourceCommit, path: realModelPath, gitBlobSHA1: gitSHA1, format: "step",
            licenseSourceID: "lib-a", byteCount: modelFile.count, sha256: sha256)
        let modelGzip = try gzip(try encoder.encode(modelRecord) + Data([0x0A]))
        let indexFile = ElectronicsRemoteFile(path: indexPath, bytes: indexGzip2.count,
            sha256: ElectronicsRemoteDigest.sha256(indexGzip2), role: "search-index", sourceID: "lib-a")
        let chunkFile = ElectronicsRemoteFile(path: chunkPath, bytes: chunkGzip.count,
            sha256: ElectronicsRemoteDigest.sha256(chunkGzip), role: "normalized-2d-records", sourceID: "lib-a")
        let originalsFile = ElectronicsRemoteFile(path: "originals/lib-a.zip", bytes: originals.count,
            sha256: ElectronicsRemoteDigest.sha256(originals), role: "original-2d-sources", sourceID: "lib-a")
        let catalog = ElectronicsRemoteCatalog(dataVersion: "v1-" + versionSuffix,
            datasetSHA256: dataset, producerRevision: producer, toolingSHA256: tooling,
            sources: [.init(id: "lib-a", repository: "https://github.com/sparkfun/SparkFun-KiCad-Libraries.git",
                commit: sourceCommit,
                license: .init(id: "MIT", attribution: "SparkFun", url: "https://example.invalid/license"),
                recordCount: 1, sourceStatus: "normalized", statuses: ["converted": 1], kinds: ["symbol": 1],
                originalFileCount: 1, originalBytes: originals.count, index: indexFile, chunks: [chunkFile],
                originals: originalsFile)],
            modelIndex: ElectronicsRemoteFile(path: "models.jsonl.gz", bytes: modelGzip.count,
                sha256: ElectronicsRemoteDigest.sha256(modelGzip), role: "model-index"),
            modelCount: 1)
        let catalogData = try encoder.encode(catalog)
        let manifest = ElectronicsRemoteManifest(dataVersion: catalog.dataVersion, datasetSHA256: dataset,
            producerRevision: producer, toolingSHA256: tooling,
            files: [
                .init(path: "catalog.json", bytes: catalogData.count, sha256: ElectronicsRemoteDigest.sha256(catalogData), role: "catalog"),
                .init(path: "upstreams.lock.json", bytes: 2, sha256: ElectronicsRemoteDigest.sha256(Data("{}".utf8)), role: "upstream-lock"),
                indexFile, chunkFile, originalsFile,
                .init(path: "models.jsonl.gz", bytes: modelGzip.count, sha256: ElectronicsRemoteDigest.sha256(modelGzip), role: "model-index")
            ])
        let manifestData = try encoder.encode(manifest)
        let publication = ElectronicsRemotePublication(tag: "data-" + catalog.dataVersion,
            dataVersion: catalog.dataVersion, producerRevision: producer, datasetSHA256: dataset,
            assets: [
                .init(name: "catalog.json", bytes: catalogData.count, sha256: ElectronicsRemoteDigest.sha256(catalogData), role: "catalog"),
                .init(name: "manifest.json", bytes: manifestData.count, sha256: ElectronicsRemoteDigest.sha256(manifestData), role: "manifest"),
                .init(name: "upstreams.lock.json", bytes: 2, sha256: ElectronicsRemoteDigest.sha256(Data("{}".utf8)), role: "upstreams.lock"),
                .init(name: "models.jsonl.gz", bytes: modelGzip.count, sha256: ElectronicsRemoteDigest.sha256(modelGzip), role: "model-index"),
                .init(name: "lib-a-2d.zip", bytes: package.count, sha256: ElectronicsRemoteDigest.sha256(package), role: "single-upstream-2d-library"),
                .init(name: "floe-electronics-all-2d.zip", bytes: full.count, sha256: ElectronicsRemoteDigest.sha256(full), role: "all-2d-libraries")
            ])
        let releaseData = try encoder.encode(publication)
        return .init(releaseData: releaseData, publication: publication, catalogData: catalogData,
            catalog: catalog, manifestData: manifestData, manifest: manifest, modelGzip: modelGzip,
            modelBytes: modelFile, model: modelRecord, indexGzip: indexGzip2, chunkGzip: chunkGzip,
            packageBytes: package, fullPackageBytes: full, partRecord: partRecord)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
