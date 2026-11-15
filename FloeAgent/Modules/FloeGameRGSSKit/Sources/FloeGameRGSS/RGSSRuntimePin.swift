// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import Darwin

public struct RGSSRuntimePinFile: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let bytes: Int
    public let role: String

    public init(path: String, sha256: String, bytes: Int, role: String) {
        self.path = path
        self.sha256 = sha256
        self.bytes = bytes
        self.role = role
    }
}

public struct RGSSRuntimeSourceArchive: Codable, Equatable, Sendable {
    public let fileName: String
    public let sha256: String
    public let bytes: Int
    public let url: URL
    public let sourceCommit: String

    public init(fileName: String, sha256: String, bytes: Int, url: URL, sourceCommit: String) {
        self.fileName = fileName
        self.sha256 = sha256
        self.bytes = bytes
        self.url = url
        self.sourceCommit = sourceCommit
    }
}

/// A reviewed, separately distributed Web runtime. The engine is GPL-2.0-or-later
/// and is intentionally not embedded in the App target; this package copies it
/// only into an explicit Web artifact from a caller-supplied, hash-verified pack.
public struct RGSSRuntimePin: Codable, Equatable, Sendable {
    public let id: String
    public let engineVersion: RGSSVersion
    public let upstreamRepository: URL
    public let sourceCommit: String
    public let binaryProvenanceCommit: String
    public let license: String
    public let files: [RGSSRuntimePinFile]
    public let sourceArchive: RGSSRuntimeSourceArchive
    public let requiresAsyncify: Bool
    public let supportsJSPI: Bool
    public let supportsThreads: Bool
    public let notes: [String]

    public init(id: String, engineVersion: RGSSVersion, upstreamRepository: URL,
                sourceCommit: String, binaryProvenanceCommit: String, license: String,
                files: [RGSSRuntimePinFile], sourceArchive: RGSSRuntimeSourceArchive,
                requiresAsyncify: Bool, supportsJSPI: Bool, supportsThreads: Bool,
                notes: [String]) {
        self.id = id
        self.engineVersion = engineVersion
        self.upstreamRepository = upstreamRepository
        self.sourceCommit = sourceCommit
        self.binaryProvenanceCommit = binaryProvenanceCommit
        self.license = license
        self.files = files
        self.sourceArchive = sourceArchive
        self.requiresAsyncify = requiresAsyncify
        self.supportsJSPI = supportsJSPI
        self.supportsThreads = supportsThreads
        self.notes = notes
    }

    public func file(_ path: String) -> RGSSRuntimePinFile? {
        files.first(where: { $0.path == path })
    }
}

public enum RGSSRuntimePinCatalog {
    /// The exact bytes deployed on the upstream `built` branch
    /// (07e1519f9a2b9100512c567e97455fa3c77a3221), generated from source
    /// e0437fdc5be29507e78d148a2b3f02d26ee1c779. No game assets are included.
    public static let mkxpWebAsyncifyRGSS1 = RGSSRuntimePin(
        id: "mkxp-web-asyncify-e0437fd",
        engineVersion: .rgss1,
        upstreamRepository: URL(string: "https://github.com/pulsejet/mkxp-web")!,
        sourceCommit: "e0437fdc5be29507e78d148a2b3f02d26ee1c779",
        binaryProvenanceCommit: "07e1519f9a2b9100512c567e97455fa3c77a3221",
        license: "GPL-2.0-or-later",
        files: [
            .init(path: "mkxp.js", sha256: "99c34f7bdeb1a2f8686a3623a08b2054c2888307c5b30e9a5abe84b880c60ab8", bytes: 290_574, role: "emscripten-loader"),
            .init(path: "mkxp.wasm", sha256: "d7d0dd69be63a9b56123e68002095d4a784497093457b4092f8010553c073eeb", bytes: 5_217_852, role: "rgss1-asyncify-engine"),
            .init(path: "rgss.rb", sha256: "1a2f2c7b65335c498ceada25342b841d65e0f082aaae533d8b51665539f6647d", bytes: 38_461, role: "reviewed-rgss-ruby-shim"),
            .init(path: "COPYING", sha256: "8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643", bytes: 18_092, role: "gpl-2.0-text")
        ],
        sourceArchive: .init(
            fileName: "mkxp-web-e0437fd-source.tar.gz",
            sha256: "9b085dd82aa7a715ce6b900186c3ce2ab5b3cae929708f350ad503e0760d4de5",
            bytes: 509_483,
            url: URL(string: "https://codeload.github.com/pulsejet/mkxp-web/tar.gz/e0437fdc5be29507e78d148a2b3f02d26ee1c779")!,
            sourceCommit: "e0437fdc5be29507e78d148a2b3f02d26ee1c779"),
        requiresAsyncify: true,
        supportsJSPI: false,
        supportsThreads: false,
        notes: [
            "RGSS1/mruby engine compiled with Emscripten Asyncify; the upstream Asyncify engine requires a main_update_loop callback or a project-specific event-loop port.",
            "The engine was built from the pinned upstream source commit; the binary bytes are shipped only as a separately distributed Web resource with the complete corresponding source archive.",
            "No RTP, game, font, Enterbrain DLL or proprietary asset is part of this pack.",
            "No general evaluator, host filesystem mount or native API bridge is exposed by the harness."
        ])

    public static let all: [RGSSRuntimePin] = [mkxpWebAsyncifyRGSS1]

    public static func pin(id: String) throws -> RGSSRuntimePin {
        guard let value = all.first(where: { $0.id == id }) else {
            throw RGSSRuntimeError.runtimePackMissing(id)
        }
        return value
    }
}

/// A verified on-disk engine pack. The caller supplies it; no network download
/// or hidden cache is created here.
public struct RGSSRuntimePack: Sendable {
    public let directory: URL
    public let pin: RGSSRuntimePin

    public init(directory: URL, pin: RGSSRuntimePin = RGSSRuntimePinCatalog.mkxpWebAsyncifyRGSS1) throws {
        guard directory.isFileURL else { throw RGSSRuntimeError.runtimePackMissing(directory.path) }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.directory = root
        self.pin = pin
        _ = try verifiedFiles()
    }

    public func fileURL(_ path: String) throws -> URL {
        guard pin.file(path) != nil else { throw RGSSRuntimeError.runtimePackMissing(path) }
        let url = directory.appendingPathComponent(path)
        guard url.standardizedFileURL.path.hasPrefix(directory.path + "/") else {
            throw RGSSRuntimeError.unsafeRelativePath(path)
        }
        return url
    }

    public func verifiedFiles() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for file in pin.files {
            let url = try fileURL(file.path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw RGSSRuntimeError.runtimePackMissing(file.path)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = (attributes[.size] as? NSNumber)?.intValue, size == file.bytes else {
                throw RGSSRuntimeError.runtimePackDigestMismatch(file.path)
            }
            guard file.bytes <= 16 * 1_024 * 1_024 else {
                throw RGSSRuntimeError.runtimePackFileTooLarge(file.path)
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count == file.bytes, Self.digest(data) == file.sha256 else {
                throw RGSSRuntimeError.runtimePackDigestMismatch(file.path)
            }
            result[file.path] = data
        }
        _ = try sourceArchiveData()
        return result
    }

    public func sourceArchiveData() throws -> Data {
        let source = directory.appendingPathComponent(pin.sourceArchive.fileName)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw RGSSRuntimeError.runtimePackMissing(pin.sourceArchive.fileName)
        }
        let data = try Data(contentsOf: source, options: [.mappedIfSafe])
        guard data.count == pin.sourceArchive.bytes,
              Self.digest(data) == pin.sourceArchive.sha256 else {
            throw RGSSRuntimeError.runtimePackDigestMismatch(pin.sourceArchive.fileName)
        }
        return data
    }

    /// Copies only pinned engine files plus reviewed notices/source offer into a
    /// new target directory. Never overwrites an existing pack.
    public func install(to target: URL) throws -> RGSSRuntimePack {
        guard target.isFileURL, !FileManager.default.fileExists(atPath: target.path) else {
            throw RGSSRuntimeError.io("runtime pack destination already exists")
        }
        let parent = target.deletingLastPathComponent().standardizedFileURL
        guard !(parent.path + "/").hasPrefix(directory.path + "/") else {
            throw RGSSRuntimeError.io("runtime pack destination is inside the source pack")
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".rgss-pack-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        for file in pin.files {
            let source = try fileURL(file.path)
            let destination = stage.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        }
        for optional in ["SOURCE-OFFER.md", "THIRD-PARTY-NOTICES.md", "SHA256SUMS"] {
            let source = directory.appendingPathComponent(optional)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.copyItem(at: source, to: stage.appendingPathComponent(optional))
        }
        let archive = try sourceArchiveData()
        try archive.write(to: stage.appendingPathComponent(pin.sourceArchive.fileName), options: [.atomic])
        _ = try RGSSRuntimePack(directory: stage, pin: pin)
        guard rename(stage.path, target.path) == 0 else {
            if errno == EEXIST { throw RGSSRuntimeError.io("runtime pack destination already exists") }
            throw RGSSRuntimeError.io("publish runtime pack")
        }
        return try RGSSRuntimePack(directory: target, pin: pin)
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
