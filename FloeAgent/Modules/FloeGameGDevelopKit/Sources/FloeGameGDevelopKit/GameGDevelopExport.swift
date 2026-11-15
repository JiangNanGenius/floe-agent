// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameBuildKit

public enum GameGDevelopPlatform: String, Codable, Equatable, Sendable {
    case macOSUniversal
    case linuxX86_64

    public var executableRelativePath: String {
        switch self {
        case .macOSUniversal: "GDevelop 5.app/Contents/MacOS/GDevelop 5"
        case .linuxX86_64: "gdevelop"
        }
    }

    public var runtimeIndexRelativePath: String {
        switch self {
        case .macOSUniversal: "GDevelop 5.app/Contents/Resources/GDJS/Runtime/index.html"
        case .linuxX86_64: "resources/GDJS/Runtime/index.html"
        }
    }
}

/// Immutable, reviewed official GDevelop release used by this adapter. The
/// asset hashes are the release bytes verified while building this component;
/// the script rechecks them before extraction.
public struct GameGDevelopSDKPin: Codable, Equatable, Sendable {
    public let version: String
    public let sourceTag: String
    public let sourceCommit: String
    public let license: String
    public let releasePage: String
    public let macOSAssetName: String
    public let macOSAssetSHA256: String
    public let linuxAssetName: String
    public let linuxAssetURL: String
    public let linuxAssetSHA256: String

    public static let official56287 = GameGDevelopSDKPin(
        version: "5.6.287",
        sourceTag: "v5.6.287",
        sourceCommit: "cfaccd2c20bba2b43fea529523042249c90b9a41",
        license: "MIT",
        releasePage: "https://github.com/4ian/GDevelop/releases/tag/v5.6.287",
        macOSAssetName: "GDevelop-5.6.287-universal-mac.zip",
        macOSAssetSHA256: "796c400bf38486146286f1c09d2605f4dc1cc00627e1ee7a06344919ac2ff7db",
        linuxAssetName: "gdevelop-5.6.287-linux.zip",
        linuxAssetURL: "https://gdevelop-releases.s3.amazonaws.com/master/latest/gdevelop-5.6.287.zip",
        linuxAssetSHA256: "d40a70cbb9e16b1ec14a9ad9e864a58120a4b310ff6f99adfb44a57804fc8c05")

    public func assetName(for platform: GameGDevelopPlatform) -> String {
        platform == .macOSUniversal ? macOSAssetName : linuxAssetName
    }

    public func assetSHA256(for platform: GameGDevelopPlatform) -> String {
        platform == .macOSUniversal ? macOSAssetSHA256 : linuxAssetSHA256
    }
}

/// The receipt written by Tools/gdevelop-export.py after it verified the
/// release archive. The Swift verifier checks this before trusting an
/// extracted SDK tree.
public struct GameGDevelopSDKReceipt: Codable, Equatable, Sendable {
    public let version: String
    public let platform: GameGDevelopPlatform
    public let assetName: String
    public let assetSHA256: String
    public let assetVerified: Bool
    public let executableRelativePath: String
    public let runtimeIndexRelativePath: String
    public let runtimeIndexSHA256: String
}

public struct GameGDevelopSDKVerification: Equatable, Sendable {
    public let receipt: GameGDevelopSDKReceipt
    public let executableURL: URL
    public let runtimeIndexURL: URL
}

public enum GameGDevelopSDKVerifier {
    public static func verify(extractedRoot: URL, platform: GameGDevelopPlatform,
                              pin: GameGDevelopSDKPin = .official56287) throws -> GameGDevelopSDKVerification {
        let root = extractedRoot.standardizedFileURL.resolvingSymlinksInPath()
        let receiptURL = root.appendingPathComponent("sdk-receipt.json")
        guard let data = try? Data(contentsOf: receiptURL),
              let receipt = try? JSONDecoder().decode(GameGDevelopSDKReceipt.self, from: data) else {
            throw GameGDevelopError.sdkMismatch("missing sdk-receipt.json")
        }
        guard receipt.version == pin.version, receipt.platform == platform,
              receipt.assetName == pin.assetName(for: platform),
              receipt.assetSHA256 == pin.assetSHA256(for: platform), receipt.assetVerified,
              receipt.executableRelativePath == platform.executableRelativePath,
              receipt.runtimeIndexRelativePath == platform.runtimeIndexRelativePath,
              isDigest(receipt.runtimeIndexSHA256) else {
            throw GameGDevelopError.sdkMismatch("receipt does not match pinned release")
        }
        let executable = root.appendingPathComponent(receipt.executableRelativePath)
        let runtimeIndex = root.appendingPathComponent(receipt.runtimeIndexRelativePath)
        guard isRegularFileWithoutSymlink(executable), isRegularFileWithoutSymlink(runtimeIndex) else {
            throw GameGDevelopError.sdkMismatch("SDK executable or runtime index missing")
        }
        guard let indexData = try? Data(contentsOf: runtimeIndex),
              GameDigest.sha256(indexData) == receipt.runtimeIndexSHA256 else {
            throw GameGDevelopError.sdkMismatch("runtime index hash mismatch")
        }
        return .init(receipt: receipt, executableURL: executable, runtimeIndexURL: runtimeIndex)
    }

    private static func isRegularFileWithoutSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    public static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public struct GameGDevelopCommand: Codable, Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String?

    public init(executable: String, arguments: [String], workingDirectory: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    public func buildKitCommand() -> GameHostCommand {
        .init(executable: executable, arguments: arguments, workingDirectory: workingDirectory)
    }
}

public struct GameGDevelopExportPlan: Codable, Equatable, Sendable {
    public let engine: GameEngineID
    public let engineVersion: String
    public let platform: GameGDevelopPlatform
    public let sourceRoot: String
    public let projectPath: GameRelativePath
    public let sdkRoot: String
    public let workspace: String
    public let output: String
    public let artifactName: String
    public let inputs: GameGDevelopInputDeclaration
    public let commands: [GameGDevelopCommand]

    public func validate() throws {
        guard engine == .gdevelop, GameGDevelopProjectDocument.validText(engineVersion) else {
            throw GameGDevelopError.exportPlanInvalid("engine")
        }
        guard isAbsolute(sourceRoot), isAbsolute(sdkRoot), isAbsolute(workspace), isAbsolute(output) else {
            throw GameGDevelopError.exportPlanInvalid("paths must be absolute")
        }
        guard output != workspace, output.hasPrefix(workspace + "/") else {
            throw GameGDevelopError.exportPlanInvalid("output must be inside workspace")
        }
        guard !projectPath.value.hasPrefix("/"), !projectPath.value.split(separator: "/").contains(".."),
              projectPath.value.lowercased().hasSuffix(".json") else {
            throw GameGDevelopError.exportPlanInvalid("project path")
        }
        guard !commands.isEmpty, commands.allSatisfy({ !$0.executable.isEmpty && $0.arguments.count <= 64 }) else {
            throw GameGDevelopError.exportPlanInvalid("commands")
        }
    }

    public func jsonData() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private func isAbsolute(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains("\0")
    }
}

public enum GameGDevelopExportPlanner {
    /// Builds a typed existing-host plan. It never stages, copies, downloads,
    /// spawns or exports anything; the host executes the commands through its
    /// existing execution service and verifies the returned artifact.
    public static func plan(source: GameProjectContext,
                            projectPath: GameRelativePath,
                            sdkRoot: URL,
                            workspace: URL,
                            output: URL,
                            platform: GameGDevelopPlatform,
                            pin: GameGDevelopSDKPin = .official56287,
                            inputs: GameGDevelopInputDeclaration? = nil,
                            exportScriptURL: URL) throws -> GameGDevelopExportPlan {
        // The host rechecks this context before executing the plan.
        let sourceRoot = source.rootURL.path
        let sdkPath = sdkRoot.standardizedFileURL.path
        let workspacePath = workspace.standardizedFileURL.path
        let outputPath = output.standardizedFileURL.path
        guard isInside(output: outputPath, parent: workspacePath) else {
            throw GameGDevelopError.exportPlanInvalid("output must be inside workspace")
        }
        let declaration: GameGDevelopInputDeclaration
        if let inputs {
            declaration = inputs
        } else {
            declaration = try GameGDevelopInputDeclaration.starter()
        }
        let script = exportScriptURL.standardizedFileURL.path
        guard FileManager.default.isExecutableFile(atPath: script) || script.lowercased().hasSuffix(".py") else {
            throw GameGDevelopError.exportPlanInvalid("export script")
        }
        let arguments = [
            script,
            "--sdk-root", sdkPath,
            "--source", sourceRoot,
            "--project", projectPath.value,
            "--workspace", workspacePath,
            "--output", outputPath,
            "--platform", platform.rawValue,
            "--sdk-version", pin.version,
            "--sdk-sha256", pin.assetSHA256(for: platform),
            "--inputs", GameGDevelopTemplate.inputFileName
        ]
        let plan = GameGDevelopExportPlan(
            engine: .gdevelop, engineVersion: pin.version, platform: platform,
            sourceRoot: sourceRoot, projectPath: projectPath, sdkRoot: sdkPath,
            workspace: workspacePath, output: outputPath,
            artifactName: "gdevelop-web", inputs: declaration,
            commands: [.init(executable: "python3", arguments: arguments, workingDirectory: workspacePath)])
        try plan.validate()
        return plan
    }

    private static func isInside(output: String, parent: String) -> Bool {
        output.hasPrefix(parent + "/") && !output.contains("/../") && output != parent
    }
}

public struct GameGDevelopExportResult: Sendable {
    public let plan: GameGDevelopExportPlan
    public let commandResults: [GameHostResult]
}

/// Runs the plan's commands through FloeGameBuildKit's existing host port.
/// The port owns process execution, cancellation, environment resolution and
/// resource limits; this package adds no executor and performs no native
/// download or install.
public actor GameGDevelopExportRunner {
    private let host: any GameBuildHostPort
    public init(host: any GameBuildHostPort) { self.host = host }

    public func run(_ plan: GameGDevelopExportPlan) async throws -> GameGDevelopExportResult {
        try plan.validate()
        var results: [GameHostResult] = []
        for command in plan.commands {
            try Task.checkCancellation()
            let result = try await host.run(command.buildKitCommand())
            results.append(result)
            guard result.exitCode == 0 else {
                throw GameGDevelopError.io("export command failed with exit \(result.exitCode)")
            }
        }
        return .init(plan: plan, commandResults: results)
    }
}
