// SPDX-License-Identifier: MPL-2.0
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import FloeGameCore
import FloeGameGDevelopKit

private enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case failure(String)
    var description: String {
        switch self {
        case .usage(let value): "usage: \(value)"
        case .failure(let value): value
        }
    }
}

private func json<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func writeTemplate(output: URL, title: String) throws {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: output.path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else { throw CLIError.failure("output is a file") }
        let contents = try FileManager.default.contentsOfDirectory(atPath: output.path)
        guard contents.isEmpty else { throw CLIError.failure("output directory is not empty") }
    } else {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }
    let files = try GameGDevelopTemplate.makeProject(title: title)
    for (path, data) in files.sorted(by: { $0.key.value < $1.key.value }) {
        let target = output.appendingPathComponent(path.value)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: [.atomic])
    }
    let projectPath = try GameRelativePath(GameGDevelopTemplate.projectFileName)
    guard let projectData = files[projectPath] else { throw CLIError.failure("template project missing") }
    let project = try GameGDevelopProjectDocument(data: projectData)
    print(try json(project.summary))
}

private func run(_ arguments: [String]) throws {
    guard let command = arguments.first else {
        throw CLIError.usage("""
        floe-gdevelop-export template <outputDir> [title]
        floe-gdevelop-export inspect <sourceRoot>
        floe-gdevelop-export plan <sourceRoot> <project.json> <sdkRoot> <workspace> <outputDir> [macOSUniversal|linuxX86_64]
        floe-gdevelop-export verify <artifactDir> [--sdk-version 5.6.287]
        floe-gdevelop-export sdk-verify <extractedSdkRoot> <macOSUniversal|linuxX86_64>
        """)
    }
    switch command {
    case "template":
        guard arguments.count >= 2 else { throw CLIError.usage("template <outputDir> [title]") }
        let output = URL(fileURLWithPath: arguments[1])
        let title = arguments.count >= 3 ? arguments[2] : "Floe GDevelop Project"
        try writeTemplate(output: output, title: title)
    case "inspect":
        guard arguments.count == 2 else { throw CLIError.usage("inspect <sourceRoot>") }
        let inspector = try GameGDevelopInspector()
        let inspection = try inspector.inspect(rootURL: URL(fileURLWithPath: arguments[1]))
        print(try json(inspection))
    case "plan":
        guard arguments.count >= 6 else {
            throw CLIError.usage("plan <sourceRoot> <project.json> <sdkRoot> <workspace> <outputDir> [platform]")
        }
        let sourceRoot = URL(fileURLWithPath: arguments[1])
        let projectPath = try GameRelativePath(arguments[2])
        let sdkRoot = URL(fileURLWithPath: arguments[3])
        let workspace = URL(fileURLWithPath: arguments[4])
        let output = URL(fileURLWithPath: arguments[5])
        let platform: GameGDevelopPlatform
        if arguments.count >= 7 {
            guard let parsed = GameGDevelopPlatform(rawValue: arguments[6]) else {
                throw CLIError.failure("unknown platform \(arguments[6])")
            }
            platform = parsed
        } else {
            platform = .macOSUniversal
        }
        guard let script = GameGDevelopTooling.exportScriptURL else {
            throw CLIError.failure("bundled gdevelop-export.py is missing")
        }
        let id = UUID()
        let context = try GameProjectContext(projectID: id, owner: .space(recordID: id),
                                             rootURL: sourceRoot, savedRevision: "cli-plan")
        let plan = try GameGDevelopExportPlanner.plan(
            source: context, projectPath: projectPath, sdkRoot: sdkRoot,
            workspace: workspace, output: output, platform: platform,
            exportScriptURL: script)
        print(try json(plan))
    case "verify":
        guard arguments.count >= 2 else { throw CLIError.usage("verify <artifactDir>") }
        let directory = URL(fileURLWithPath: arguments[1])
        var sdkVersion: String?
        if let index = arguments.firstIndex(of: "--sdk-version"), index + 1 < arguments.count {
            sdkVersion = arguments[index + 1]
        }
        let manifest = try GameGDevelopArtifactVerifier.verify(directory: directory, sdkVersion: sdkVersion)
        print(try json(manifest))
    case "sdk-verify":
        guard arguments.count == 3 else { throw CLIError.usage("sdk-verify <extractedSdkRoot> <platform>") }
        guard let platform = GameGDevelopPlatform(rawValue: arguments[2]) else {
            throw CLIError.failure("unknown platform")
        }
        let verified = try GameGDevelopSDKVerifier.verify(
            extractedRoot: URL(fileURLWithPath: arguments[1]), platform: platform)
        print(try json(verified.receipt))
    case "version":
        print(try json(GameGDevelopSDKPin.official56287))
    default:
        throw CLIError.usage("unknown command \(command)")
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data(("error: \(error)\n").utf8))
    exit(1)
}
