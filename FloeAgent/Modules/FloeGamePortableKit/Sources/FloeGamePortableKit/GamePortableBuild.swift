// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin
import FloeGameCore

public enum GamePortableBuildKind: String, Codable, Equatable, Sendable {
    case sourceCopy
    case mvTemplateAssembly
    case mvCoreAssembly
    case loveJSPackage
    case renpyWebBuild
}

public struct GamePortableBuildStep: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case assembleFiles
        case archiveSource
        case runNode
        case runRenPy
        case verifyArtifact
    }
    public let kind: Kind
    public let executable: String?
    /// Placeholders are {{projectRoot}}, {{output}}, {{resources}}, {{sdk}},
    /// {{title}}, {{memory}}. They are data for the host's existing job service,
    /// never an implicitly executed command in this package.
    public let arguments: [String]
    public let outputs: [String]
    public let note: String?

    public init(kind: Kind, executable: String?, arguments: [String],
                outputs: [String], note: String?) {
        self.kind = kind; self.executable = executable
        self.arguments = arguments; self.outputs = outputs; self.note = note
    }
}

public struct GamePortableBuildPlan: Codable, Equatable, Sendable {
    public let engine: GameEngineID
    public let kind: GamePortableBuildKind
    public let entry: GameRelativePath
    public let steps: [GamePortableBuildStep]
    public let requiresExternalTool: Bool
    public let resourceID: String?
    public let outputs: [String]
    public let notes: [String]

    public init(engine: GameEngineID, kind: GamePortableBuildKind, entry: GameRelativePath,
                steps: [GamePortableBuildStep], requiresExternalTool: Bool,
                resourceID: String?, outputs: [String], notes: [String]) {
        self.engine = engine; self.kind = kind; self.entry = entry
        self.steps = steps; self.requiresExternalTool = requiresExternalTool
        self.resourceID = resourceID; self.outputs = outputs; self.notes = notes
    }
}

public struct GamePortableBuildRequest: Sendable {
    public let project: GamePortableProjectDescriptor
    public let outputURL: URL
    public let resources: GamePortablePreparedResources?
    public let sdkURL: URL?
    public let title: String
    public let memoryBytes: Int

    public init(project: GamePortableProjectDescriptor, outputURL: URL,
                resources: GamePortablePreparedResources?, sdkURL: URL? = nil,
                title: String, memoryBytes: Int = 33_554_432) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 128, (8_388_608...268_435_456).contains(memoryBytes) else {
            throw GamePortableError.invalidArtifact("build title or memory")
        }
        try GamePortableBuildChecks.output(outputURL, outside: [project.rootURL])
        self.project = project; self.outputURL = outputURL
        self.resources = resources; self.sdkURL = sdkURL
        self.title = title; self.memoryBytes = memoryBytes
    }
}

public struct GamePortableBuildOutput: Codable, Equatable, Sendable {
    public let directory: URL
    public let entry: GameRelativePath
    public let toolchain: [String]
    public init(directory: URL, entry: GameRelativePath, toolchain: [String]) {
        self.directory = directory; self.entry = entry; self.toolchain = toolchain
    }
}

/// The host injects its existing authorized jobs/build service. This package
/// deliberately has no Process, shell, network or generic evaluator backend.
public protocol GamePortableBuildPort: Sendable {
    func execute(_ plan: GamePortableBuildPlan,
                 request: GamePortableBuildRequest) async throws -> GamePortableBuildOutput
}

enum GamePortableBuildChecks {
    static func output(_ output: URL, outside roots: [URL]) throws {
        guard output.isFileURL, !output.lastPathComponent.isEmpty,
              output.standardizedFileURL.path != "/" else {
            throw GamePortableError.invalidArtifact("output URL")
        }
        let resolved = output.standardizedFileURL.resolvingSymlinksInPath()
        for root in roots {
            let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            guard !resolved.path.hasPrefix(rootPath) else {
                throw GamePortableError.invalidArtifact("output inside source")
            }
        }
        if FileManager.default.fileExists(atPath: resolved.path) {
            throw GamePortableError.destinationExists
        }
    }
}

/// Deterministic, on-device assembly for the official MIT MV CoreScript and
/// source projects. It copies bytes and concatenates the pinned module order; it
/// never executes JavaScript or a model-authored command.
public enum GamePortableMVAssembler {
    public static let coreNames = ["rpg_core", "rpg_managers", "rpg_objects", "rpg_scenes", "rpg_sprites", "rpg_windows"]

    @discardableResult
    public static func assemble(project: GamePortableProjectDescriptor,
                                resources: GamePortablePreparedResources?,
                                to outputURL: URL) throws -> GamePortableBuildOutput {
        try GamePortableBuildChecks.output(outputURL, outside: [project.rootURL])
        let parent = outputURL.deletingLastPathComponent()
        try GamePortableFileAccess.directory(parent)
        let stage = parent.appendingPathComponent(".floe-portable-" + UUID().uuidString.lowercased())
        defer { GamePortableFileAccess.removeIfExists(stage) }
        _ = try GamePortableFileAccess.copyTree(from: project.rootURL, to: stage)
        let builtCore = project.contains("js/rpg_core.js")
        if !builtCore {
            let modules = GamePortableAdapterSupport.hasPrefix(project, "js/rpg_core/")
            if modules {
                try concatenate(project: project, stage: stage)
            } else {
                guard let resources, resources.engine == .rpgMakerMV else {
                    throw GamePortableError.resourceMismatch("prepared MV CoreScript")
                }
                try resources.verify()
                try mergeCore(resources: resources, into: stage)
            }
        }
        guard FileManager.default.fileExists(atPath: stage.appendingPathComponent("index.html").path) else {
            throw GamePortableError.invalidArtifact("index.html")
        }
        guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, outputURL.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw GamePortableError.destinationExists }
            throw GamePortableError.io("publish MV artifact")
        }
        return .init(directory: outputURL, entry: GamePortableAdapterSupport.path("index.html"),
                     toolchain: ["mv-core-assembly", "floe-game-portable"])
    }

    private static func concatenate(project: GamePortableProjectDescriptor, stage: URL) throws {
        for name in coreNames {
            let orderPath = name + ".json"
            guard project.contains(orderPath) else {
                throw GamePortableError.invalidArtifact("missing \(orderPath)")
            }
            let orderData = try project.read(orderPath, maximumBytes: 262_144)
            guard let list = try JSONSerialization.jsonObject(with: orderData) as? [String], !list.isEmpty else {
                throw GamePortableError.invalidArtifact(orderPath)
            }
            var output = Data()
            for path in list {
                guard path.hasPrefix("js/\(name)/"), path.hasSuffix(".js") else {
                    throw GamePortableError.invalidArtifact("non-core module \(path)")
                }
                let data = try project.read(path, maximumBytes: 2 * 1_024 * 1_024)
                if !output.isEmpty { output.append(0x0A) }
                output.append(data)
            }
            try GamePortableFileAccess.writeAtomic(output, to: stage.appendingPathComponent("js/\(name).js"))
        }
    }

    private static func mergeCore(resources: GamePortablePreparedResources, into stage: URL) throws {
        for name in coreNames {
            let path = "js/\(name).js"
            let data = try resources.read(path)
            try GamePortableFileAccess.writeAtomic(data, to: stage.appendingPathComponent(path))
        }
        for file in resources.manifest.files where file.path.value.hasPrefix("js/libs/") {
            let data = try resources.read(file.path.value)
            try GamePortableFileAccess.writeAtomic(data, to: stage.appendingPathComponent(file.path.value))
        }
        for file in resources.manifest.files where file.path.value.hasPrefix("licenses/") {
            let data = try resources.read(file.path.value)
            try GamePortableFileAccess.writeAtomic(data, to: stage.appendingPathComponent(file.path.value))
        }
    }
}
