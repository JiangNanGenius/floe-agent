// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin
import FloeGameCore

public enum RGSSWebRuntimeMode: String, Codable, Equatable, Sendable {
    /// An original Floe template/fixture whose event loop and keys are known.
    case verifiedFixture
    /// A new project created from the Floe template.
    case template
    /// An imported project. The adapter seals the source but does not claim
    /// gameplay until the project-specific port is reviewed.
    case importedRequiresReview
}

public struct RGSSOmittedFile: Codable, Equatable, Sendable {
    public let path: String
    public let reason: String
    public init(path: String, reason: String) { self.path = path; self.reason = reason }
}

public struct RGSSManifestFile: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let bytes: Int
    public let role: String
    public init(path: String, sha256: String, bytes: Int, role: String) {
        self.path = path; self.sha256 = sha256; self.bytes = bytes; self.role = role
    }
}

public struct RGSSRuntimeManifest: Codable, Equatable, Sendable {
    public let format: String
    public let version: Int
    public let engine: GameEngineID
    public let rgssVersion: RGSSVersion
    public let sourceProjectID: UUID
    public let sourceRevision: String
    public let sourceRootSHA256: String
    public let runtimePinID: String
    public let runtimeLicense: String
    public let runtimeSourceCommit: String
    public let runtimeSourceArchiveSHA256: String
    public let entry: String
    public let requiredContentSecurityPolicy: String
    public let stateLimitBytes: Int
    public let mode: RGSSWebRuntimeMode
    public let input: RGSSInputDeclaration
    public let preload: [String]
    public let files: [RGSSManifestFile]
    public let omitted: [RGSSOmittedFile]
    public let compatibility: RGSSProjectInspection
    public let warnings: [String]
    public let limitations: [String]

    public init(format: String = "floe-rgss-runtime-manifest", version: Int = 1,
                engine: GameEngineID, rgssVersion: RGSSVersion, sourceProjectID: UUID,
                sourceRevision: String, sourceRootSHA256: String, runtimePinID: String,
                runtimeLicense: String, runtimeSourceCommit: String,
                runtimeSourceArchiveSHA256: String, entry: String,
                requiredContentSecurityPolicy: String, stateLimitBytes: Int,
                mode: RGSSWebRuntimeMode, input: RGSSInputDeclaration, preload: [String],
                files: [RGSSManifestFile], omitted: [RGSSOmittedFile],
                compatibility: RGSSProjectInspection, warnings: [String], limitations: [String]) {
        self.format = format
        self.version = version
        self.engine = engine
        self.rgssVersion = rgssVersion
        self.sourceProjectID = sourceProjectID
        self.sourceRevision = sourceRevision
        self.sourceRootSHA256 = sourceRootSHA256
        self.runtimePinID = runtimePinID
        self.runtimeLicense = runtimeLicense
        self.runtimeSourceCommit = runtimeSourceCommit
        self.runtimeSourceArchiveSHA256 = runtimeSourceArchiveSHA256
        self.entry = entry
        self.requiredContentSecurityPolicy = requiredContentSecurityPolicy
        self.stateLimitBytes = stateLimitBytes
        self.mode = mode
        self.input = input
        self.preload = preload
        self.files = files
        self.omitted = omitted
        self.compatibility = compatibility
        self.warnings = warnings
        self.limitations = limitations
    }
}

public struct RGSSRuntimeConfig: Codable, Equatable, Sendable {
    public let engine: GameEngineID
    public let engineVersion: Int
    public let jsURL: String
    public let wasmURL: String
    public let stateLimit: Int
    public let input: RGSSInputDeclaration
    public let preload: [String]
    /// Base64 bytes for preload-only files. All other project files are fetched
    /// on demand from the sealed package's same-origin game/ directory.
    public let files: [String: String]

    public init(engine: GameEngineID, engineVersion: Int, jsURL: String, wasmURL: String,
                stateLimit: Int, input: RGSSInputDeclaration, preload: [String],
                files: [String: String]) {
        self.engine = engine
        self.engineVersion = engineVersion
        self.jsURL = jsURL
        self.wasmURL = wasmURL
        self.stateLimit = stateLimit
        self.input = input
        self.preload = preload
        self.files = files
    }
}

public struct RGSSArtifact: Sendable {
    public let package: GameWebArtifactPackage
    public let manifest: RGSSRuntimeManifest
    public let directory: URL
    public let omitted: [RGSSOmittedFile]
    public let warnings: [String]

    public init(package: GameWebArtifactPackage, manifest: RGSSRuntimeManifest,
                directory: URL, omitted: [RGSSOmittedFile], warnings: [String]) {
        self.package = package
        self.manifest = manifest
        self.directory = directory
        self.omitted = omitted
        self.warnings = warnings
    }
}

/// Deterministic, source-bound Web artifact builder. It copies the entire
/// project tree except known native/encrypted runtime files, adds the reviewed
/// separately distributed engine pack, and seals the result through the
/// existing GameWebArtifactPackage. It does not mutate the source repository.
public struct RGSSArtifactBuilder: Sendable {
    public let limits: GameRepositoryLimits

    public init(limits: GameRepositoryLimits? = nil) {
        self.limits = limits ?? (try! GameRepositoryLimits())
    }

    public func build(source: GameProjectContext, engine: GameEngineID, pack: RGSSRuntimePack,
                      mode: RGSSWebRuntimeMode, to target: URL) throws -> RGSSArtifact {
        let profile = try RGSSEngineProfiles.profile(for: engine)
        let support = try RGSSRuntimeMatrix.support(for: engine)
        guard case .verifiedAsyncify(let pinID) = support.web, pinID == pack.pin.id,
              pack.pin.engineVersion == profile.version else {
            throw RGSSRuntimeError.unsupportedWebEngine(engine)
        }
        guard source.rootURL.isFileURL else { throw RGSSRuntimeError.invalidArtifact("source is not a file URL") }
        let sourceRoot = source.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard target.isFileURL else { throw RGSSRuntimeError.invalidArtifact("target is not a file URL") }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw GameProjectError.destinationExists
        }
        let parent = target.deletingLastPathComponent().standardizedFileURL
        guard !(parent.path + "/").hasPrefix(sourceRoot.path + "/") else {
            throw RGSSRuntimeError.invalidArtifact("artifact must be outside the source root")
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".rgss-artifact-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }

        let inspection = try RGSSCompatibilityInspector().inspect(rootURL: sourceRoot)
        guard inspection.engine == engine else {
            throw RGSSRuntimeError.invalidArtifact("inspected engine does not match the requested engine")
        }
        if !inspection.encryptedArchives.isEmpty && !inspection.scriptsPresent {
            throw RGSSRuntimeError.encryptedScripts(inspection.encryptedArchives)
        }
        guard inspection.scriptsPresent else { throw RGSSRuntimeError.missingScripts(profile.scriptsPath) }
        let input = try loadInput(sourceRoot: sourceRoot, engine: engine)
        let packFiles = try pack.verifiedFiles()
        let packJS = try requiredPackData(pack, packFiles, path: "mkxp.js")
        let packWASM = try requiredPackData(pack, packFiles, path: "mkxp.wasm")
        let packRuby = try requiredPackData(pack, packFiles, path: "rgss.rb")
        let packLicense = try requiredPackData(pack, packFiles, path: "COPYING")

        var files: [RGSSManifestFile] = []
        var omitted: [RGSSOmittedFile] = []
        var fileData: [String: Data] = [:]
        var total = 0
        let sourceFiles = try enumerateSource(sourceRoot)
        for (relative, url) in sourceFiles {
            try Task.checkCancellation()
            if isNativeOrEncrypted(relative) {
                omitted.append(.init(path: relative, reason: nativeReason(relative)))
                continue
            }
            if relative == "rgss.rb" {
                omitted.append(.init(path: relative, reason: "replaced by the reviewed pinned rgss.rb at artifact runtime"))
                continue
            }
            let bytes = try boundedRead(url, maximum: limits.maximumFileBytes)
            guard total <= limits.maximumProjectBytes - bytes.count else {
                throw RGSSRuntimeError.invalidArtifact("project exceeds the artifact byte limit")
            }
            total += bytes.count
            fileData[relative] = bytes
            files.append(.init(path: "game/" + relative, sha256: RGSSRuntimePack.digest(bytes),
                               bytes: bytes.count, role: "project"))
        }
        // The sealed game tree is rooted at game/, just as mkxp's gameFolder.
        fileData["rgss.rb"] = packRuby
        files.append(.init(path: "game/rgss.rb", sha256: RGSSRuntimePack.digest(packRuby),
                           bytes: packRuby.count, role: "reviewed-rgss-ruby-shim"))
        let inputBytes = try input.jsonData()
        fileData["floe-inputs.json"] = inputBytes

        let scriptRelative = profile.scriptsPath
        guard fileData[scriptRelative] != nil else {
            throw RGSSRuntimeError.missingScripts(scriptRelative)
        }
        var preload = ["rgss.rb", scriptRelative]
        if let systemBytes = fileData[profile.systemDataPath], systemBytes.count <= 1_048_576 {
            preload.append(profile.systemDataPath)
        }
        var preloadFiles: [String: String] = [:]
        for relative in preload {
            guard let bytes = fileData[relative] else { continue }
            preloadFiles[relative] = bytes.base64EncodedString()
        }
        let stateLimit = RGSSWebRuntimeRequirements.stateLimitBytes
        let config = RGSSRuntimeConfig(
            engine: engine, engineVersion: profile.version.rawValue,
            jsURL: "engine/mkxp.js", wasmURL: "engine/mkxp.wasm",
            stateLimit: stateLimit, input: input, preload: preload, files: preloadFiles)
        let html = try makeIndex(config: config)

        let gameRoot = stage.appendingPathComponent("game")
        try FileManager.default.createDirectory(at: gameRoot, withIntermediateDirectories: true)
        for (relative, bytes) in fileData.sorted(by: { $0.key < $1.key }) {
            let path = try safeRelative(relative)
            let destination = gameRoot.appendingPathComponent(path.value)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try WriteHelper.atomicWrite(bytes, to: destination)
        }
        try WriteHelper.atomicWrite(inputBytes, to: stage.appendingPathComponent("floe-inputs.json"))
        let engineRoot = stage.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engineRoot, withIntermediateDirectories: true)
        try WriteHelper.atomicWrite(packJS, to: engineRoot.appendingPathComponent("mkxp.js"))
        try WriteHelper.atomicWrite(packWASM, to: engineRoot.appendingPathComponent("mkxp.wasm"))
        try WriteHelper.atomicWrite(try resource("floe-runtime", ext: "js", subdirectory: "Resources"),
                                    to: stage.appendingPathComponent("floe-runtime.js"))
        try WriteHelper.atomicWrite(html, to: stage.appendingPathComponent("index.html"))
        let licenses = stage.appendingPathComponent("licenses")
        try FileManager.default.createDirectory(at: licenses, withIntermediateDirectories: true)
        try WriteHelper.atomicWrite(packLicense, to: licenses.appendingPathComponent("MKXP-COPYING.txt"))
        files.append(.init(path: "licenses/MKXP-COPYING.txt", sha256: RGSSRuntimePack.digest(packLicense),
                           bytes: packLicense.count, role: "license"))
        for optional in ["SOURCE-OFFER.md", "THIRD-PARTY-NOTICES.md", "SHA256SUMS"] {
            let url = pack.directory.appendingPathComponent(optional)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let data = try boundedRead(url, maximum: 1_048_576)
            try WriteHelper.atomicWrite(data, to: licenses.appendingPathComponent(optional))
            files.append(.init(path: "licenses/" + optional, sha256: RGSSRuntimePack.digest(data),
                               bytes: data.count, role: "license"))
        }
        let archive = try pack.sourceArchiveData()
        try WriteHelper.atomicWrite(archive, to: licenses.appendingPathComponent(pack.pin.sourceArchive.fileName))
        files.append(.init(path: "licenses/" + pack.pin.sourceArchive.fileName,
                           sha256: RGSSRuntimePack.digest(archive), bytes: archive.count, role: "source-archive"))
        for record in [
            ("engine/mkxp.js", packJS, "engine-loader"),
            ("engine/mkxp.wasm", packWASM, "engine-wasm"),
            ("floe-runtime.js", try resource("floe-runtime", ext: "js", subdirectory: "Resources"), "runtime-harness"),
            ("index.html", html, "entry"),
            ("floe-inputs.json", inputBytes, "keyboard-declaration")
        ] {
            files.append(.init(path: record.0, sha256: RGSSRuntimePack.digest(record.1), bytes: record.1.count, role: record.2))
        }

        let sourceDigest = sourceRootSHA256(files.filter { $0.role == "project" })
        var warnings = inspection.warnings
        if mode == .importedRequiresReview {
            warnings.append("Imported project sealed for review; successful import or data editing is not proof of gameplay.")
        }
        if inspection.encryptedArchives.isEmpty == false {
            warnings.append("Encrypted archives were omitted from the Web artifact and remain in the repository.")
        }
        if omitted.contains(where: { $0.reason.contains("native") }) {
            warnings.append("Native EXE/DLL files were omitted from the Web artifact and remain in the repository.")
        }
        let limitations = [
            "Save progress is a virtual save-file bridge (Save*.rxdata/rvdata/rvdata2), not a live VM snapshot.",
            "The Web adapter runs only the pinned RGSS1 Asyncify engine; VX/VX Ace Web gameplay is not claimed.",
            "The Linux guest adapter is typed integration only; no Linux guest was launched in this lane.",
            "RTP, Enterbrain DLLs, proprietary fonts and third-party game content are never bundled."
        ]
        let manifest = RGSSRuntimeManifest(
            engine: engine, rgssVersion: profile.version, sourceProjectID: source.projectID,
            sourceRevision: source.savedRevision, sourceRootSHA256: sourceDigest,
            runtimePinID: pack.pin.id, runtimeLicense: pack.pin.license,
            runtimeSourceCommit: pack.pin.sourceCommit,
            runtimeSourceArchiveSHA256: pack.pin.sourceArchive.sha256,
            entry: "index.html", requiredContentSecurityPolicy: RGSSWebRuntimeRequirements.requiredContentSecurityPolicy,
            stateLimitBytes: stateLimit, mode: mode, input: input, preload: preload,
            files: files.sorted { $0.path < $1.path }, omitted: omitted.sorted { $0.path < $1.path },
            compatibility: inspection, warnings: warnings, limitations: limitations)
        try WriteHelper.atomicWrite(try JSONEncoder.prettySorted.encode(manifest),
                                    to: stage.appendingPathComponent("floe-runtime-manifest.json"))
        let package = try GameWebArtifactPackage.build(
            source: source, engine: engine, entry: try GameRelativePath("index.html"),
            to: target, contentRoot: stage, limits: limits)
        try package.verify()
        return .init(package: package, manifest: manifest, directory: target,
                     omitted: omitted.sorted { $0.path < $1.path }, warnings: warnings)
    }

    private func loadInput(sourceRoot: URL, engine: GameEngineID) throws -> RGSSInputDeclaration {
        let url = sourceRoot.appendingPathComponent("floe-inputs.json")
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try boundedRead(url, maximum: 65_536)
            return try RGSSInputDeclaration.decode(data, expectedEngine: engine)
        }
        return try .standard(for: engine)
    }

    private func requiredPackData(_ pack: RGSSRuntimePack, _ files: [String: Data], path: String) throws -> Data {
        guard let data = files[path] else { throw RGSSRuntimeError.runtimePackMissing(path) }
        return data
    }

    private func enumerateSource(_ root: URL) throws -> [(String, URL)] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]) else {
            throw RGSSRuntimeError.io("cannot enumerate source")
        }
        var result: [(String, URL)] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            _ = try safeRelative(relative)
            guard result.count < limits.maximumEntries else {
                throw RGSSRuntimeError.invalidArtifact("too many source files")
            }
            result.append((relative, url))
        }
        return result.sorted { $0.0 < $1.0 }
    }

    private func isNativeOrEncrypted(_ relative: String) -> Bool {
        let lower = relative.lowercased()
        let ext = (lower as NSString).pathExtension
        if ["exe", "dll", "so", "dylib"].contains(ext) { return true }
        if lower.hasSuffix(".rgssad") || lower.hasSuffix(".rgss2a") || lower.hasSuffix(".rgss3a") { return true }
        return false
    }

    private func nativeReason(_ relative: String) -> String {
        let lower = relative.lowercased()
        if lower.hasSuffix(".rgssad") || lower.hasSuffix(".rgss2a") || lower.hasSuffix(".rgss3a") {
            return "encrypted RGSS archive omitted from Web artifact; original preserved"
        }
        return "native Windows executable/library omitted from Web artifact; original preserved and never executed"
    }

    private func safeRelative(_ relative: String) throws -> GameRelativePath {
        do { return try GameRelativePath(relative) }
        catch { throw RGSSRuntimeError.unsafeRelativePath(relative) }
    }

    private func boundedRead(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw RGSSRuntimeError.unsafeRelativePath(url.lastPathComponent)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.intValue, size <= maximum else {
            throw RGSSRuntimeError.invalidArtifact("file exceeds limit: \(url.lastPathComponent)")
        }
        return try Data(contentsOf: url)
    }

    private func makeIndex(config: RGSSRuntimeConfig) throws -> Data {
        let template = try resource("index.template", ext: "html", subdirectory: "Resources")
        guard var text = String(data: template, encoding: .utf8),
              let range = text.range(of: "__FLOE_RGSS_CONFIG__") else {
            throw RGSSRuntimeError.invalidArtifact("index template missing config marker")
        }
        var json = String(data: try JSONEncoder().encode(config), encoding: .utf8) ?? "{}"
        json = json.replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
        text.replaceSubrange(range, with: json)
        guard let data = text.data(using: .utf8) else {
            throw RGSSRuntimeError.invalidArtifact("index template encoding")
        }
        return data
    }

    private func sourceRootSHA256(_ files: [RGSSManifestFile]) -> String {
        let canonical = files.map { "\($0.path)\u{0}\($0.sha256)\u{0}\($0.bytes)" }.joined(separator: "\n")
        return RGSSRuntimePack.digest(Data(canonical.utf8))
    }

    private func resource(_ name: String, ext: String, subdirectory: String? = nil) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdirectory) else {
            throw RGSSRuntimeError.io("missing module resource \(name).\(ext)")
        }
        return try Data(contentsOf: url)
    }
}

extension JSONEncoder {
    static var prettySorted: JSONEncoder {
        let value = JSONEncoder()
        value.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return value
    }
}

private enum WriteHelper {
    static func atomicWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        do {
            try data.write(to: temporary, options: [.atomic])
            guard rename(temporary.path, url.path) == 0 else {
                if errno == EEXIST { try? FileManager.default.removeItem(at: temporary); throw RGSSRuntimeError.io("destination exists") }
                throw RGSSRuntimeError.io("publish \(url.lastPathComponent)")
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
