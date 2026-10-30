// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

/// Read-only renderer routing. Extensions requiring an unbundled decoder are
/// identified explicitly, rather than handed to Quick Look as a blank success.
public enum EngineeringPreviewKind: String, Codable, Sendable {
    case mesh, dxf, dwg, cadSurface, gerber, unsupported

    public static func identify(_ path: String) -> Self? {
        switch (path as NSString).pathExtension.lowercased() {
        case "stl", "obj", "ply", "off", "3ds", "dae", "fbx", "3mf", "amf", "gltf", "glb", "wrl", "bim": .mesh
        case "dxf": .dxf
        case "dwg": .dwg
        case "step", "stp", "iges", "igs", "brep": .cadSurface
        case "gbr", "ger", "gerber", "gtl", "gbl", "gts", "gbs", "gto", "gbo", "gko", "gm1", "gml", "drl", "xln": .gerber
        case "dwt", "dgn", "fcstd", "ifc", "3dm", "kicad_pcb", "kicad_sch": .unsupported
        default: nil
        }
    }
}

/// Exact renderer selected for a package. A GLB/glTF file uses the bundled
/// three.js r176 `GLTFLoader` scene path; other meshes keep the existing
/// Online3DViewer static import. Nothing here fetches a remote decoder.
public enum EngineeringPreviewBackend: String, Codable, Sendable {
    case threeGLTF
    case online3DViewer
    case dxfViewer
    case occt
    case gerber
}

/// Explicit resource budgets. The default is the existing 20 MiB / 32-file
/// package limit. A caller that intentionally offers a larger *read-only*
/// route must pass its own limits and surface them to the user; there is no
/// silent relaxation inside the loader.
public struct EngineeringPreviewLimits: Sendable, Equatable {
    public let maximumBytes: Int
    public let maximumFiles: Int

    public static let standard = EngineeringPreviewLimits(
        maximumBytes: EngineeringPreviewPackage.maximumBytes,
        maximumFiles: EngineeringPreviewPackage.maximumFiles)

    public init(maximumBytes: Int, maximumFiles: Int) {
        self.maximumBytes = max(1, maximumBytes)
        self.maximumFiles = max(1, maximumFiles)
    }
}

/// Durable identity of the bytes the viewer was given. The source hash is the
/// first file's bytes (the selected model/drawing); every resource also keeps
/// its own hash. The viewer never writes these files.
public struct EngineeringPreviewProvenance: Codable, Sendable, Equatable {
    public struct Resource: Codable, Sendable, Equatable {
        public let name: String
        public let byteCount: Int
        public let sha256: String

        public init(name: String, byteCount: Int, sha256: String) {
            self.name = name
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

    public let sourceName: String
    public let sourceByteCount: Int
    public let sourceSHA256: String
    public let resourceByteCount: Int
    public let resources: [Resource]
    public let maximumBytes: Int
    public let maximumFiles: Int

    public var resourceCount: Int { resources.count }
    public var isWithinDefaultLimits: Bool {
        maximumBytes <= EngineeringPreviewPackage.maximumBytes
            && maximumFiles <= EngineeringPreviewPackage.maximumFiles
    }
}

/// Stable machine-readable diagnosis. Product surfaces localize `code`; the
/// detail is bounded document-supplied text (never HTML or a remote URL).
public struct EngineeringPreviewIssue: Codable, Sendable, Equatable, Identifiable {
    public enum Severity: String, Codable, Sendable {
        case info, warning, blocking
    }

    public enum Code: String, Codable, Sendable {
        case invalidContainer
        case unsupportedVersion
        case unsupportedRequiredExtension
        case unsupportedExtension
        case externalResourceBlocked
        case missingBuffer
        case missingResource
        case unsupportedPrimitiveMode
        case sparseAccessor
        case compressedAsset
        case packageTruncated
    }

    public let severity: Severity
    public let code: Code
    /// Bounded, human-readable specifics (names only; no payload content).
    public let detail: String

    public var id: String { "\(severity.rawValue):\(code.rawValue):\(detail)" }

    public init(severity: Severity, code: Code, detail: String) {
        self.severity = severity
        self.code = code
        self.detail = String(detail.prefix(512))
    }
}

public struct EngineeringAnimationSummary: Codable, Sendable, Equatable {
    public let name: String
    public let channelCount: Int
    public let samplerCount: Int
    public let interpolations: [String]
    public let durationSeconds: Double?

    public init(name: String, channelCount: Int, samplerCount: Int,
                interpolations: [String], durationSeconds: Double?) {
        self.name = name
        self.channelCount = channelCount
        self.samplerCount = samplerCount
        self.interpolations = interpolations
        self.durationSeconds = durationSeconds
    }
}

/// Source-level preflight of the selected glTF/GLB container. This is a
/// statement about what the bundled loader can be asked to parse, not a
/// runtime render result.
public struct EngineeringPreviewDiagnostics: Codable, Sendable, Equatable {
    public let formatVersion: String?
    public let generator: String?
    public let sceneCount: Int
    public let nodeCount: Int
    public let meshCount: Int
    public let primitiveCount: Int
    public let primitiveModeCounts: [String: Int]
    public let unsupportedPrimitiveModes: [Int]
    public let materialCount: Int
    public let textureCount: Int
    public let imageCount: Int
    public let cameraCount: Int
    public let animationCount: Int
    public let animations: [EngineeringAnimationSummary]
    public let skinCount: Int
    public let morphPrimitiveCount: Int
    public let morphTargetCount: Int
    public let sparseAccessorCount: Int
    public let requiredExtensions: [String]
    public let usedExtensions: [String]
    public let unsupportedRequiredExtensions: [String]
    public let unsupportedExtensions: [String]
    public let issues: [EngineeringPreviewIssue]

    public static let empty = EngineeringPreviewDiagnostics(
        formatVersion: nil, generator: nil, sceneCount: 0, nodeCount: 0,
        meshCount: 0, primitiveCount: 0, primitiveModeCounts: [:],
        unsupportedPrimitiveModes: [], materialCount: 0, textureCount: 0,
        imageCount: 0, cameraCount: 0, animationCount: 0, animations: [],
        skinCount: 0, morphPrimitiveCount: 0, morphTargetCount: 0,
        sparseAccessorCount: 0, requiredExtensions: [], usedExtensions: [],
        unsupportedRequiredExtensions: [], unsupportedExtensions: [], issues: [])

    public var blockingIssues: [EngineeringPreviewIssue] {
        issues.filter { $0.severity == .blocking }
    }

    public var warnings: [EngineeringPreviewIssue] {
        issues.filter { $0.severity != .info }
    }

    public var isScenePreviewAvailable: Bool { blockingIssues.isEmpty }

    public init(formatVersion: String?, generator: String?, sceneCount: Int,
                nodeCount: Int, meshCount: Int, primitiveCount: Int,
                primitiveModeCounts: [String: Int],
                unsupportedPrimitiveModes: [Int], materialCount: Int,
                textureCount: Int, imageCount: Int, cameraCount: Int,
                animationCount: Int, animations: [EngineeringAnimationSummary],
                skinCount: Int, morphPrimitiveCount: Int, morphTargetCount: Int,
                sparseAccessorCount: Int, requiredExtensions: [String],
                usedExtensions: [String], unsupportedRequiredExtensions: [String],
                unsupportedExtensions: [String], issues: [EngineeringPreviewIssue]) {
        self.formatVersion = formatVersion
        self.generator = generator
        self.sceneCount = sceneCount
        self.nodeCount = nodeCount
        self.meshCount = meshCount
        self.primitiveCount = primitiveCount
        self.primitiveModeCounts = primitiveModeCounts
        self.unsupportedPrimitiveModes = unsupportedPrimitiveModes
        self.materialCount = materialCount
        self.textureCount = textureCount
        self.imageCount = imageCount
        self.cameraCount = cameraCount
        self.animationCount = animationCount
        self.animations = animations
        self.skinCount = skinCount
        self.morphPrimitiveCount = morphPrimitiveCount
        self.morphTargetCount = morphTargetCount
        self.sparseAccessorCount = sparseAccessorCount
        self.requiredExtensions = requiredExtensions
        self.usedExtensions = usedExtensions
        self.unsupportedRequiredExtensions = unsupportedRequiredExtensions
        self.unsupportedExtensions = unsupportedExtensions
        self.issues = issues
    }
}

public struct EngineeringPreviewPackage: Codable, Sendable {
    public struct File: Codable, Sendable {
        public let name: String
        public let base64: String
    }
    public let name: String
    public let kind: EngineeringPreviewKind
    public let files: [File]
    public let missingReferences: [String]
    public let provenance: EngineeringPreviewProvenance
    public let diagnostics: EngineeringPreviewDiagnostics
    public static let maximumBytes = 20 * 1024 * 1024
    public static let maximumFiles = 32

    public var backend: EngineeringPreviewBackend? {
        switch kind {
        case .dxf, .dwg: .dxfViewer
        case .cadSurface: .occt
        case .gerber: .gerber
        case .mesh:
            switch (name as NSString).pathExtension.lowercased() {
            case "glb", "gltf": .threeGLTF
            default: .online3DViewer
            }
        case .unsupported: nil
        }
    }

    /// The WebView receives immutable bytes, no filesystem or tool capabilities.
    /// Only explicit OBJ/MTL/glTF references below the selected folder are read.
    public static func load(path: String, service: WorkspaceFileService,
                            limits: EngineeringPreviewLimits = .standard) throws -> Self {
        guard let kind = EngineeringPreviewKind.identify(path) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let base = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        var pending = [name], visited = Set<String>(), files: [File] = [], missing: [String] = []
        var resourceHashes: [EngineeringPreviewProvenance.Resource] = []
        var total = 0
        var sourceBytes: Data?
        while !pending.isEmpty {
            try Task.checkCancellation()
            let relative = pending.removeFirst()
            guard visited.insert(relative).inserted else { continue }
            guard visited.count <= limits.maximumFiles else { throw CocoaError(.fileReadTooLarge) }
            do {
                let url = try service.guardResolver.resolve(base.isEmpty ? relative : base + "/" + relative)
                try service.guardResolver.assertReadableSize(url)
                // Bound the actual read, including a file that grows after stat.
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let bytes = try handle.read(upToCount: limits.maximumBytes - total + 1) ?? Data()
                total += bytes.count
                guard total <= limits.maximumBytes else { throw CocoaError(.fileReadTooLarge) }
                if relative == name { sourceBytes = bytes }
                resourceHashes.append(EngineeringPreviewProvenance.Resource(
                    name: relative, byteCount: bytes.count,
                    sha256: FloeDigest.sha256Hex(bytes)))
                files.append(File(name: relative, base64: bytes.base64EncodedString()))
                let prefix = (relative as NSString).deletingLastPathComponent
                for reference in references(bytes, extension: url.pathExtension.lowercased()) {
                    let child = prefix.isEmpty ? reference : prefix + "/" + reference
                    if safeReference(child) {
                        if !visited.contains(child), !pending.contains(child) {
                            guard visited.count + pending.count < limits.maximumFiles else { throw CocoaError(.fileReadTooLarge) }
                            pending.append(child)
                        }
                    }
                    else { missing.append(reference) }
                }
            } catch {
                if relative == name || (error as NSError).code == NSFileReadTooLargeError { throw error }
                missing.append(relative)
            }
        }
        let provenance = EngineeringPreviewProvenance(
            sourceName: name, sourceByteCount: sourceBytes?.count ?? 0,
            sourceSHA256: FloeDigest.sha256Hex(sourceBytes ?? Data()),
            resourceByteCount: total, resources: resourceHashes,
            maximumBytes: limits.maximumBytes, maximumFiles: limits.maximumFiles)
        let diagnostics = inspect(name: name, kind: kind, files: files,
                                  mainBytes: sourceBytes, missing: missing)
        return Self(name: name, kind: kind, files: files, missingReferences: missing,
                    provenance: provenance, diagnostics: diagnostics)
    }

    public static func single(name: String, bytes: Data,
                              limits: EngineeringPreviewLimits = .standard) throws -> Self {
        guard bytes.count <= limits.maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        guard let kind = EngineeringPreviewKind.identify(name) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let digest = FloeDigest.sha256Hex(bytes)
        let files = [File(name: name, base64: bytes.base64EncodedString())]
        let missing = references(bytes, extension: (name as NSString).pathExtension.lowercased())
        let provenance = EngineeringPreviewProvenance(
            sourceName: name, sourceByteCount: bytes.count,
            sourceSHA256: digest, resourceByteCount: bytes.count,
            resources: [.init(name: name, byteCount: bytes.count, sha256: digest)],
            maximumBytes: limits.maximumBytes, maximumFiles: limits.maximumFiles)
        let diagnostics = inspect(name: name, kind: kind, files: files,
                                  mainBytes: bytes, missing: missing)
        return Self(name: name, kind: kind, files: files, missingReferences: missing,
                    provenance: provenance, diagnostics: diagnostics)
    }

    /// Loads one file from a resolved URL. `includeSiblingResources` is opt-in:
    /// callers that only hold a single-file grant (chat attachment copies, run
    /// receipts) keep it false and every external reference is reported, never
    /// silently resolved outside the grant. Callers that pass true must have
    /// access to the file's directory and accept the same bounded package
    /// rules; the file itself is only ever read.
    public static func load(fileURL: URL, displayName: String? = nil,
                            includeSiblingResources: Bool = false,
                            limits: EngineeringPreviewLimits = .standard) throws -> Self {
        let resolved = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { throw CocoaError(.fileNoSuchFile) }
        guard EngineeringPreviewKind.identify(resolved.lastPathComponent) != nil else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let presentedName = displayName.map { ($0 as NSString).lastPathComponent } ?? resolved.lastPathComponent
        guard !presentedName.isEmpty,
              (presentedName as NSString).pathExtension.lowercased()
                == (resolved.lastPathComponent as NSString).pathExtension.lowercased(),
              EngineeringPreviewKind.identify(presentedName) != nil else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let loaded: Self
        if includeSiblingResources {
            let root = resolved.deletingLastPathComponent()
            let standard = WorkspacePathGuard(rootURL: root)
            let guardResolver = WorkspacePathGuard(
                rootURL: root,
                maxReadBytes: max(limits.maximumBytes, standard.maxReadBytes))
            let service = WorkspaceFileService(guard: guardResolver)
            loaded = try load(path: resolved.lastPathComponent, service: service, limits: limits)
        } else {
            let values = try resolved.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            guard size <= limits.maximumBytes else { throw CocoaError(.fileReadTooLarge) }
            let handle = try FileHandle(forReadingFrom: resolved)
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: limits.maximumBytes + 1) ?? Data()
            try Task.checkCancellation()
            guard bytes.count <= limits.maximumBytes else { throw CocoaError(.fileReadTooLarge) }
            loaded = try single(name: resolved.lastPathComponent, bytes: bytes, limits: limits)
        }
        guard presentedName != loaded.name else { return loaded }
        return Self(name: presentedName, kind: loaded.kind, files: loaded.files,
                    missingReferences: loaded.missingReferences,
                    provenance: loaded.provenance, diagnostics: loaded.diagnostics)
    }

    static func safeReference(_ path: String) -> Bool {
        guard !path.isEmpty, path.count < 1024, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains(":"), !path.contains("\\"), !path.contains("%"),
              !path.split(separator: "/").contains("..") else { return false }
        return ["mtl", "bin", "png", "jpg", "jpeg", "webp", "bmp", "gif",
                "ktx2", "basis", "dds", "tga", "tif", "tiff", "avif",
                "exr", "hdr"].contains((path as NSString).pathExtension.lowercased())
    }

    private static func references(_ bytes: Data, extension ext: String) -> [String] {
        if ["gltf", "glb"].contains(ext),
           let json = try? sceneJSON(name: "x." + ext, bytes: bytes) {
            return gltfReferences(json)
        }
        guard ["obj", "mtl"].contains(ext), let text = String(data: bytes, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { return nil }
            let command = parts[0].lowercased()
            guard (ext == "obj" && command == "mtllib") || (ext == "mtl" && command.hasPrefix("map_")) else { return nil }
            // Option-bearing MTL paths are reported as unresolved, not guessed.
            return String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
    }

    private static func gltfReferences(_ json: [String: Any]) -> [String] {
        ["buffers", "images"].flatMap { key in
            (json[key] as? [[String: Any]] ?? []).compactMap { $0["uri"] as? String }
        }.filter { !$0.hasPrefix("data:") }
    }

    // MARK: - glTF/GLB preflight

    private static let primitiveModeNames = [
        0: "POINTS", 1: "LINES", 2: "LINE_LOOP", 3: "LINE_STRIP",
        4: "TRIANGLES", 5: "TRIANGLE_STRIP", 6: "TRIANGLE_FAN"
    ]

    /// Extensions the bundled three.js r176 loader (plus the locally bundled
    /// Draco/meshopt/KTX2 decoders) is wired to parse. This is deliberately a
    /// conservative list: an unknown *required* extension blocks the preview
    /// instead of being skipped into a misleading partial scene.
    private static let supportedSceneExtensions: Set<String> = [
        "KHR_draco_mesh_compression", "EXT_meshopt_compression",
        "KHR_texture_basisu", "KHR_texture_transform", "KHR_mesh_quantization",
        "KHR_materials_unlit", "KHR_materials_clearcoat",
        "KHR_materials_transmission", "KHR_materials_volume",
        "KHR_materials_ior", "KHR_materials_specular", "KHR_materials_sheen",
        "KHR_materials_iridescence", "KHR_materials_anisotropy",
        "KHR_materials_dispersion", "KHR_materials_emissive_strength",
        "KHR_lights_punctual",
        "EXT_mesh_gpu_instancing", "EXT_texture_webp"
    ]

    private static func isSceneContainer(_ name: String) -> Bool {
        ["glb", "gltf"].contains((name as NSString).pathExtension.lowercased())
    }

    private static func inspect(name: String, kind: EngineeringPreviewKind,
                                files: [File], mainBytes: Data?,
                                missing: [String]) -> EngineeringPreviewDiagnostics {
        guard kind == .mesh, isSceneContainer(name), let mainBytes else { return .empty }
        var issues: [EngineeringPreviewIssue] = []
        let json: [String: Any]
        do {
            json = try sceneJSON(name: name, bytes: mainBytes)
        } catch let error as SceneContainerError {
            issues.append(.init(severity: .blocking, code: error.code, detail: error.detail))
            return emptySceneDiagnostics(issues: issues)
        } catch {
            issues.append(.init(severity: .blocking, code: .invalidContainer,
                                detail: error.localizedDescription))
            return emptySceneDiagnostics(issues: issues)
        }
        let asset = json["asset"] as? [String: Any]
        let version = asset?["version"] as? String
        let generator = asset?["generator"] as? String
        if let version, !version.hasPrefix("2.") {
            issues.append(.init(severity: .blocking, code: .unsupportedVersion, detail: version))
        }

        let required = stringArray(json["extensionsRequired"])
        let used = stringArray(json["extensionsUsed"])
        let unsupportedRequired = required.filter { !supportedSceneExtensions.contains($0) }
        let unsupportedUsed = used.filter { !supportedSceneExtensions.contains($0) }
        for extensionName in unsupportedRequired {
            issues.append(.init(severity: .blocking, code: .unsupportedRequiredExtension,
                                detail: extensionName))
        }
        for extensionName in unsupportedUsed where !unsupportedRequired.contains(extensionName) {
            issues.append(.init(severity: .warning, code: .unsupportedExtension,
                                detail: extensionName))
        }
        for extensionName in required where ["KHR_draco_mesh_compression",
                                             "EXT_meshopt_compression",
                                             "KHR_texture_basisu"].contains(extensionName) {
            issues.append(.init(severity: .info, code: .compressedAsset, detail: extensionName))
        }

        let accessors = json["accessors"] as? [[String: Any]] ?? []
        let sparseAccessorCount = accessors.filter { $0["sparse"] != nil }.count
        if sparseAccessorCount > 0 {
            issues.append(.init(severity: .info, code: .sparseAccessor,
                                detail: String(sparseAccessorCount)))
        }

        var primitiveModeCounts: [String: Int] = [:]
        var unsupportedModes: [Int] = []
        var primitiveCount = 0
        var morphPrimitiveCount = 0
        var morphTargetCount = 0
        let meshes = json["meshes"] as? [[String: Any]] ?? []
        for mesh in meshes {
            for primitive in mesh["primitives"] as? [[String: Any]] ?? [] {
                primitiveCount += 1
                let mode = (primitive["mode"] as? NSNumber)?.intValue ?? 4
                if let modeName = primitiveModeNames[mode] {
                    primitiveModeCounts[modeName, default: 0] += 1
                } else {
                    unsupportedModes.append(mode)
                }
                if let targets = primitive["targets"] as? [Any], !targets.isEmpty {
                    morphPrimitiveCount += 1
                    morphTargetCount += targets.count
                }
            }
        }
        if !unsupportedModes.isEmpty {
            issues.append(.init(
                severity: unsupportedModes.count == primitiveCount ? .blocking : .warning,
                code: .unsupportedPrimitiveMode,
                detail: unsupportedModes.map(String.init).joined(separator: ",")))
        }

        let buffers = json["buffers"] as? [[String: Any]] ?? []
        let images = json["images"] as? [[String: Any]] ?? []
        let presentNames = Set(files.map(\.name))
        let missingSet = Set(missing)
        let mainPrefix = (name as NSString).deletingLastPathComponent
        func candidates(_ uri: String) -> [String] {
            guard !mainPrefix.isEmpty, !uri.hasPrefix("/"), !uri.contains(":") else { return [uri] }
            return [uri, mainPrefix + "/" + uri]
        }
        var classified: Set<String> = []
        for buffer in buffers {
            guard let uri = buffer["uri"] as? String, !uri.hasPrefix("data:") else { continue }
            let names = candidates(uri)
            classified.formUnion(names)
            if !names.contains(where: presentNames.contains)
                || names.contains(where: missingSet.contains) {
                issues.append(.init(severity: .blocking, code: .missingBuffer, detail: uri))
            }
        }
        for image in images {
            guard let uri = image["uri"] as? String, !uri.hasPrefix("data:") else { continue }
            let names = candidates(uri)
            classified.formUnion(names)
            if !names.contains(where: presentNames.contains) {
                let code: EngineeringPreviewIssue.Code =
                    safeReference(uri) ? .missingResource : .externalResourceBlocked
                issues.append(.init(severity: .warning, code: code, detail: uri))
            }
        }
        for reference in missing where !classified.contains(reference) {
            issues.append(.init(severity: .warning, code: .missingResource, detail: reference))
        }

        let animations: [EngineeringAnimationSummary] = (json["animations"] as? [[String: Any]] ?? [])
            .enumerated().map { index, animation in
                let samplers = animation["samplers"] as? [[String: Any]] ?? []
                let interpolations = Array(Set(samplers.compactMap {
                    $0["interpolation"] as? String
                })).sorted()
                var duration: Double?
                for sampler in samplers {
                    guard let input = (sampler["input"] as? NSNumber)?.intValue,
                          input >= 0, input < accessors.count,
                          let maximum = accessors[input]["max"] as? [NSNumber],
                          let value = maximum.first?.doubleValue else { continue }
                    duration = Swift.max(duration ?? 0, value)
                }
                return EngineeringAnimationSummary(
                    name: (animation["name"] as? String) ?? "Animation \(index + 1)",
                    channelCount: (animation["channels"] as? [Any])?.count ?? 0,
                    samplerCount: samplers.count,
                    interpolations: interpolations, durationSeconds: duration)
            }

        let nodes = json["nodes"] as? [Any] ?? []
        let scenes = json["scenes"] as? [Any] ?? []
        let materials = json["materials"] as? [Any] ?? []
        let textures = json["textures"] as? [Any] ?? []
        let cameras = json["cameras"] as? [Any] ?? []
        let skins = json["skins"] as? [Any] ?? []

        return EngineeringPreviewDiagnostics(
            formatVersion: version, generator: generator,
            sceneCount: scenes.count, nodeCount: nodes.count,
            meshCount: meshes.count, primitiveCount: primitiveCount,
            primitiveModeCounts: primitiveModeCounts,
            unsupportedPrimitiveModes: unsupportedModes,
            materialCount: materials.count, textureCount: textures.count,
            imageCount: images.count, cameraCount: cameras.count,
            animationCount: animations.count, animations: animations,
            skinCount: skins.count, morphPrimitiveCount: morphPrimitiveCount,
            morphTargetCount: morphTargetCount,
            sparseAccessorCount: sparseAccessorCount,
            requiredExtensions: required, usedExtensions: used,
            unsupportedRequiredExtensions: unsupportedRequired,
            unsupportedExtensions: unsupportedUsed, issues: issues)
    }

    private static func emptySceneDiagnostics(issues: [EngineeringPreviewIssue]) -> EngineeringPreviewDiagnostics {
        EngineeringPreviewDiagnostics(
            formatVersion: nil, generator: nil, sceneCount: 0, nodeCount: 0,
            meshCount: 0, primitiveCount: 0, primitiveModeCounts: [:],
            unsupportedPrimitiveModes: [], materialCount: 0,
            textureCount: 0, imageCount: 0, cameraCount: 0,
            animationCount: 0, animations: [], skinCount: 0,
            morphPrimitiveCount: 0, morphTargetCount: 0,
            sparseAccessorCount: 0, requiredExtensions: [],
            usedExtensions: [], unsupportedRequiredExtensions: [],
            unsupportedExtensions: [], issues: issues)
    }

    private struct SceneContainerError: Error {
        let code: EngineeringPreviewIssue.Code
        let detail: String
    }

    private static func sceneJSON(name: String, bytes: Data) throws -> [String: Any] {
        let ext = (name as NSString).pathExtension.lowercased()
        var jsonData: Data
        if ext == "glb" {
            guard bytes.count >= 20,
                  bytes[0] == 0x67, bytes[1] == 0x6C, bytes[2] == 0x54, bytes[3] == 0x46 else {
                throw SceneContainerError(code: .invalidContainer, detail: "GLB magic")
            }
            let version = uint32(bytes, 4)
            guard version == 2 else {
                throw SceneContainerError(code: .unsupportedVersion, detail: "GLB \(version)")
            }
            let declared = uint32(bytes, 8)
            guard declared <= bytes.count, declared >= 20 else {
                throw SceneContainerError(code: .invalidContainer, detail: "GLB length")
            }
            let chunkLength = Int(uint32(bytes, 12))
            let chunkType = uint32(bytes, 16)
            guard chunkType == 0x4E4F534A, chunkLength > 0, 20 + chunkLength <= declared else {
                throw SceneContainerError(code: .invalidContainer, detail: "GLB JSON chunk")
            }
            jsonData = Data(bytes[20..<(20 + chunkLength)])
        } else {
            jsonData = bytes
        }
        if jsonData.count >= 3, jsonData[0] == 0xEF, jsonData[1] == 0xBB, jsonData[2] == 0xBF {
            jsonData = Data(jsonData.dropFirst(3))
        }
        guard jsonData.count > 0 else {
            throw SceneContainerError(code: .invalidContainer, detail: "empty JSON")
        }
        guard let object = try? JSONSerialization.jsonObject(with: jsonData),
              let json = object as? [String: Any] else {
            throw SceneContainerError(code: .invalidContainer, detail: "invalid JSON")
        }
        return json
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [String]) ?? []
    }
}

// MARK: - Runtime scene contract

/// Typed state of a live GLB/glTF scene. It is produced by the bundled
/// three.js viewer and is intentionally read-only: it describes the scene,
/// playback and source identity, and never grants a mutation capability.
public struct EngineeringSceneState: Codable, Sendable, Equatable {
    public struct Node: Codable, Sendable, Equatable {
        public let path: String
        public let name: String
        public let type: String
        public let childCount: Int
        public let meshName: String?
        public let instanceCount: Int
        public let visible: Bool
    }

    public struct Scene: Codable, Sendable, Equatable {
        public let index: Int
        public let name: String
        public init(index: Int, name: String) { self.index = index; self.name = name }
    }

    public struct Camera: Codable, Sendable, Equatable {
        public let index: Int
        public let name: String
        public let type: String
    }

    public struct Clip: Codable, Sendable, Equatable {
        public let index: Int
        public let name: String
        public let durationSeconds: Double
        public let channelCount: Int
        public let interpolations: [String]
    }

    public struct Bounds: Codable, Sendable, Equatable {
        public let minimum: [Double]
        public let maximum: [Double]
        public let center: [Double]
        public let radius: Double
    }

    public let documentName: String
    public let sourceSHA256: String
    public let backend: String
    public let ready: Bool
    public let nodeCount: Int
    public let meshCount: Int
    public let instancedMeshCount: Int
    public let skinnedMeshCount: Int
    public let morphMeshCount: Int
    public let materialCount: Int
    public let textureCount: Int
    public let lightCount: Int
    public let nodes: [Node]
    public let cameras: [Camera]
    public let scenes: [Scene]
    public let activeSceneIndex: Int
    public let clips: [Clip]
    public let activeCameraIndex: Int?
    public let activeClipIndex: Int?
    public let timeSeconds: Double
    public let durationSeconds: Double
    public let playing: Bool
    public let loopMode: String
    public let speed: Double
    public let bounds: Bounds?
    public let missingResources: [String]
    public let unsupportedExtensions: [String]
    public let warnings: [String]
    public let truncatedNodes: Bool

    public init(documentName: String, sourceSHA256: String, backend: String,
                ready: Bool, nodeCount: Int, meshCount: Int,
                instancedMeshCount: Int, skinnedMeshCount: Int,
                morphMeshCount: Int, materialCount: Int, textureCount: Int,
                lightCount: Int, nodes: [Node], cameras: [Camera],
                clips: [Clip], activeCameraIndex: Int?, activeClipIndex: Int?,
                timeSeconds: Double, durationSeconds: Double, playing: Bool,
                loopMode: String, speed: Double, bounds: Bounds?,
                missingResources: [String], unsupportedExtensions: [String],
                warnings: [String], truncatedNodes: Bool,
                scenes: [Scene] = [], activeSceneIndex: Int = 0) {
        self.documentName = documentName
        self.sourceSHA256 = sourceSHA256
        self.backend = backend
        self.ready = ready
        self.nodeCount = nodeCount
        self.meshCount = meshCount
        self.instancedMeshCount = instancedMeshCount
        self.skinnedMeshCount = skinnedMeshCount
        self.morphMeshCount = morphMeshCount
        self.materialCount = materialCount
        self.textureCount = textureCount
        self.lightCount = lightCount
        self.nodes = nodes
        self.cameras = cameras
        self.scenes = scenes
        self.activeSceneIndex = activeSceneIndex
        self.clips = clips
        self.activeCameraIndex = activeCameraIndex
        self.activeClipIndex = activeClipIndex
        self.timeSeconds = timeSeconds
        self.durationSeconds = durationSeconds
        self.playing = playing
        self.loopMode = loopMode
        self.speed = speed
        self.bounds = bounds
        self.missingResources = missingResources
        self.unsupportedExtensions = unsupportedExtensions
        self.warnings = warnings
        self.truncatedNodes = truncatedNodes
    }

    private enum CodingKeys: String, CodingKey {
        case documentName, sourceSHA256, backend, ready, nodeCount, meshCount
        case instancedMeshCount, skinnedMeshCount, morphMeshCount
        case materialCount, textureCount, lightCount, nodes, cameras, clips
        case scenes, activeSceneIndex
        case activeCameraIndex, activeClipIndex, timeSeconds, durationSeconds
        case playing, loopMode, speed, bounds, missingResources
        case unsupportedExtensions, warnings, truncatedNodes
    }

    /// Decodes a bridge object tolerantly: a partial state from an older page
    /// must not blank the native controls, but every field is still typed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        documentName = try container.decodeIfPresent(String.self, forKey: .documentName) ?? ""
        sourceSHA256 = try container.decodeIfPresent(String.self, forKey: .sourceSHA256) ?? ""
        backend = try container.decodeIfPresent(String.self, forKey: .backend) ?? "threeGLTF"
        ready = try container.decodeIfPresent(Bool.self, forKey: .ready) ?? false
        nodeCount = try container.decodeIfPresent(Int.self, forKey: .nodeCount) ?? 0
        meshCount = try container.decodeIfPresent(Int.self, forKey: .meshCount) ?? 0
        instancedMeshCount = try container.decodeIfPresent(Int.self, forKey: .instancedMeshCount) ?? 0
        skinnedMeshCount = try container.decodeIfPresent(Int.self, forKey: .skinnedMeshCount) ?? 0
        morphMeshCount = try container.decodeIfPresent(Int.self, forKey: .morphMeshCount) ?? 0
        materialCount = try container.decodeIfPresent(Int.self, forKey: .materialCount) ?? 0
        textureCount = try container.decodeIfPresent(Int.self, forKey: .textureCount) ?? 0
        lightCount = try container.decodeIfPresent(Int.self, forKey: .lightCount) ?? 0
        nodes = try container.decodeIfPresent([Node].self, forKey: .nodes) ?? []
        cameras = try container.decodeIfPresent([Camera].self, forKey: .cameras) ?? []
        scenes = try container.decodeIfPresent([Scene].self, forKey: .scenes) ?? []
        activeSceneIndex = try container.decodeIfPresent(Int.self, forKey: .activeSceneIndex) ?? 0
        clips = try container.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        activeCameraIndex = try container.decodeIfPresent(Int.self, forKey: .activeCameraIndex)
        activeClipIndex = try container.decodeIfPresent(Int.self, forKey: .activeClipIndex)
        timeSeconds = try container.decodeIfPresent(Double.self, forKey: .timeSeconds) ?? 0
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        playing = try container.decodeIfPresent(Bool.self, forKey: .playing) ?? false
        loopMode = try container.decodeIfPresent(String.self, forKey: .loopMode) ?? "repeat"
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        bounds = try container.decodeIfPresent(Bounds.self, forKey: .bounds)
        missingResources = try container.decodeIfPresent([String].self, forKey: .missingResources) ?? []
        unsupportedExtensions = try container.decodeIfPresent([String].self, forKey: .unsupportedExtensions) ?? []
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        truncatedNodes = try container.decodeIfPresent(Bool.self, forKey: .truncatedNodes) ?? false
    }

    /// Bridge objects arrive as `[String: Any]`; decode through the same
    /// Codable contract so the native surface never reads ad-hoc keys.
    public static func decode(fromJSONObject object: Any) -> EngineeringSceneState? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// Complete hierarchy stays in the scene owner; callers can page it without
/// changing the bounded native toolbar state or losing the unshown tail.
public struct EngineeringSceneHierarchyPage: Codable, Sendable, Equatable {
    public let sourceSHA256: String
    public let sceneIndex: Int
    public let total: Int
    public let offset: Int
    public let nextOffset: Int?
    public let nodes: [EngineeringSceneState.Node]
}

public enum EngineeringSceneLoopMode: String, Codable, Sendable, CaseIterable {
    case once
    case repeatPlayback = "repeat"
    case pingPong = "pingpong"
}

/// Read-only playback commands. Seeking/capturing is transient: it never
/// alters the document, and the JS side restores the user's camera and
/// playback state after a capture.
public enum EngineeringSceneCommand: Sendable, Equatable {
    case play
    case pause
    case seek(seconds: Double)
    case selectClip(index: Int?)
    case loop(EngineeringSceneLoopMode)
    case speed(Double)
    case selectCamera(index: Int?)
    case selectScene(index: Int)
    case fit
    case setNodeVisible(path: String, visible: Bool)

    public var jsonObject: [String: Any] {
        switch self {
        case .play: return ["action": "play"]
        case .pause: return ["action": "pause"]
        case .seek(let seconds): return ["action": "seek", "seconds": seconds]
        case .selectClip(let index):
            return ["action": "clip", "index": index.map { $0 } ?? NSNull()]
        case .loop(let mode): return ["action": "loop", "mode": mode.rawValue]
        case .speed(let value): return ["action": "speed", "speed": value]
        case .selectCamera(let index):
            return ["action": "camera", "index": index.map { $0 } ?? NSNull()]
        case .selectScene(let index): return ["action": "scene", "index": index]
        case .fit: return ["action": "fit"]
        case .setNodeVisible(let path, let visible):
            return ["action": "nodeVisibility", "path": path, "visible": visible]
        }
    }

    public func jsonString() -> String? {
        guard JSONSerialization.isValidJSONObject(jsonObject),
              let data = try? JSONSerialization.data(withJSONObject: jsonObject) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public struct EngineeringSceneCaptureView: Codable, Sendable, Equatable {
    public var azimuthDegrees: Double
    public var elevationDegrees: Double
    public var distanceScale: Double
    public var target: [Double]?

    public init(azimuthDegrees: Double, elevationDegrees: Double,
                distanceScale: Double = 1, target: [Double]? = nil) {
        self.azimuthDegrees = azimuthDegrees
        self.elevationDegrees = elevationDegrees
        self.distanceScale = distanceScale
        self.target = target
    }

    public static let standard: [Self] = [
        .init(azimuthDegrees: 35, elevationDegrees: 20),
        .init(azimuthDegrees: 125, elevationDegrees: 20),
        .init(azimuthDegrees: 215, elevationDegrees: 20),
        .init(azimuthDegrees: 305, elevationDegrees: 20)
    ]
}

/// A bounded, read-only multi-angle capture request for AI observation. The
/// caller supplies a source-bound preview contract; the JS renderer temporarily
/// moves a clone of the camera, renders each view, and restores the user's
/// camera/playback before returning pixels.
public struct EngineeringSceneCaptureRequest: Sendable, Equatable {
    public var views: [EngineeringSceneCaptureView]
    public var width: Int
    public var height: Int
    public var clipIndex: Int?
    public var timeSeconds: Double?
    public var maximumFrames: Int
    public var maximumPNGBytes: Int
    public var maximumTotalBytes: Int

    public static let standard = EngineeringSceneCaptureRequest(
        views: EngineeringSceneCaptureView.standard, width: 1024, height: 768,
        clipIndex: nil, timeSeconds: nil,
        maximumFrames: 8, maximumPNGBytes: 8 * 1024 * 1024,
        maximumTotalBytes: 32 * 1024 * 1024)

    public init(views: [EngineeringSceneCaptureView], width: Int, height: Int,
                clipIndex: Int?, timeSeconds: Double?, maximumFrames: Int,
                maximumPNGBytes: Int, maximumTotalBytes: Int) {
        let frameLimit = min(max(maximumFrames, 1), 8)
        self.views = Array(views.prefix(frameLimit))
        self.width = min(max(width, 64), 2048)
        self.height = min(max(height, 64), 2048)
        self.clipIndex = clipIndex
        self.timeSeconds = timeSeconds.map { max(0, $0) }
        self.maximumFrames = frameLimit
        self.maximumPNGBytes = min(max(maximumPNGBytes, 1024), 16 * 1024 * 1024)
        self.maximumTotalBytes = min(max(maximumTotalBytes, 1024), 32 * 1024 * 1024)
    }

    public func jsonString() -> String? {
        var payload: [String: Any] = [
            "views": views.map { view -> [String: Any] in
                var item: [String: Any] = [
                    "azimuthDegrees": view.azimuthDegrees,
                    "elevationDegrees": view.elevationDegrees,
                    "distanceScale": view.distanceScale
                ]
                if let target = view.target, target.count == 3 {
                    item["target"] = target
                }
                return item
            },
            "width": width, "height": height,
            "maximumFrames": maximumFrames,
            "maximumPNGBytes": maximumPNGBytes,
            "maximumTotalBytes": maximumTotalBytes
        ]
        payload["clipIndex"] = clipIndex.map { $0 } ?? NSNull()
        payload["timeSeconds"] = timeSeconds ?? NSNull()
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public struct EngineeringSceneCaptureFailure: Sendable, Equatable {
    public let viewIndex: Int
    public let reason: String

    public init(viewIndex: Int, reason: String) {
        self.viewIndex = viewIndex
        self.reason = String(reason.prefix(256))
    }
}

public struct EngineeringSceneCaptureFrame: Sendable, Equatable {
    public let pngData: Data
    public let width: Int
    public let height: Int
    public let viewIndex: Int
    public let azimuthDegrees: Double
    public let elevationDegrees: Double
    public let timeSeconds: Double
    public let clipIndex: Int?
    public let sourceSHA256: String
    public let state: EngineeringSceneState?

    public init(pngData: Data, width: Int, height: Int, viewIndex: Int,
                azimuthDegrees: Double, elevationDegrees: Double,
                timeSeconds: Double, clipIndex: Int?, sourceSHA256: String,
                state: EngineeringSceneState?) {
        self.pngData = pngData
        self.width = width
        self.height = height
        self.viewIndex = viewIndex
        self.azimuthDegrees = azimuthDegrees
        self.elevationDegrees = elevationDegrees
        self.timeSeconds = timeSeconds
        self.clipIndex = clipIndex
        self.sourceSHA256 = sourceSHA256
        self.state = state
    }

    public var mimeType: String { "image/png" }
    public var byteCount: Int { pngData.count }

    /// Digest of the PNG bytes that the primary observation path persists.
    /// The source SHA above remains the document identity, not this image.
    public var pngSHA256: String { FloeDigest.sha256Hex(pngData) }

    /// Compact evidence line for a persisted `EngineeringObservations` entry.
    public var receipt: String {
        "sourceSHA256=\(sourceSHA256) imageSHA256=\(pngSHA256) "
            + "view=\(viewIndex) time=\(timeSeconds) clip=\(clipIndex.map(String.init) ?? "none")"
    }
}

public struct EngineeringSceneCaptureResult: Sendable, Equatable {
    public let frames: [EngineeringSceneCaptureFrame]
    public let failures: [EngineeringSceneCaptureFailure]

    public init(frames: [EngineeringSceneCaptureFrame],
                failures: [EngineeringSceneCaptureFailure]) {
        self.frames = frames
        self.failures = failures
    }

    public var sourceSHA256: String { frames.first?.sourceSHA256 ?? "" }
    public var isPartial: Bool { !failures.isEmpty }
}
