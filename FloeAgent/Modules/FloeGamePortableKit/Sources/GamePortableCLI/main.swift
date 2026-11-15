// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin
import FloeGameCore
import FloeGamePortableKit

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func encode<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

func engine(_ value: String) throws -> GameEngineID {
    guard let id = GameEngineID(rawValue: value) else { throw CLIError("unknown engine: \(value)") }
    return id
}

func resources(_ root: String?, _ manifest: String?) throws -> GamePortablePreparedResources? {
    if root == nil && manifest == nil { return nil }
    guard let root, let manifest else { throw CLIError("--resources and --manifest are required together") }
    return try GamePortablePreparedResources(rootURL: URL(fileURLWithPath: root),
        manifestURL: URL(fileURLWithPath: manifest))
}

func options(_ args: [String]) -> ([String], [String: String]) {
    var positional: [String] = [], flags: [String: String] = [:]
    var index = 0
    while index < args.count {
        let item = args[index]
        if item.hasPrefix("--") {
            let name = String(item.dropFirst(2))
            if index + 1 < args.count, !args[index + 1].hasPrefix("--") {
                flags[name] = args[index + 1]; index += 2; continue
            }
            flags[name] = "true"; index += 1
        } else {
            positional.append(item); index += 1
        }
    }
    return (positional, flags)
}

let usage = """
floe-game-portable <command> [options]

Read-only unless noted:
  inspect <root> [--engine <id>]       inspect one project root (no writes)
  scan <root>                          list bounded candidate roots (no selection)
  validate-inputs <floe-inputs.json>   validate the keyboard declaration
  verify <dir> --engine <id> [--resources <dir> --manifest <file>]
  plan <root> --engine <id> --output <dir> [--resources <dir> --manifest <file>] [--sdk <dir>]
  templates                            list bundled original starter templates
  pins                                 list pinned runtime manifests
  assemble-mv <root> --output <dir> [--resources <dir> --manifest <file>]  (writes a new artifact)
  overlay <engine> --directory <built-dir>                                  (writes adapter files)
"""

do {
    guard CommandLine.arguments.count >= 2 else { print(usage); exit(2) }
    let command = CommandLine.arguments[1]
    let (positional, flags) = options(Array(CommandLine.arguments.dropFirst(2)))
    switch command {
    case "inspect":
        guard let root = positional.first else { throw CLIError("inspect requires a root") }
        let project = try GamePortableProjectDescriptor(rootURL: URL(fileURLWithPath: root))
        let registry = try FloeGamePortableKit.registry()
        let engines: [GameEngineID]
        if let value = flags["engine"] { engines = [try engine(value)] }
        else { engines = FloeGamePortableKit.supportedEngines }
        var profiles: [GamePortableProfile] = []
        for id in engines { profiles.append(try registry.inspect(project, engine: id)) }
        print(try encode(profiles))
    case "scan":
        guard let root = positional.first else { throw CLIError("scan requires a root") }
        print(try encode(GamePortableRootScanner.scan(rootURL: URL(fileURLWithPath: root))))
    case "validate-inputs":
        guard let path = positional.first else { throw CLIError("validate-inputs requires a file") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        let declaration = try GamePortableInputDeclaration.decode(data)
        print(try encode(declaration))
    case "verify":
        guard let directory = positional.first, let value = flags["engine"] else {
            throw CLIError("verify requires <dir> --engine <id>")
        }
        let prepared = try resources(flags["resources"], flags["manifest"])
        let id = try engine(value)
        let registry = try FloeGamePortableKit.registry()
        let result = try registry.verifyArtifact(at: URL(fileURLWithPath: directory),
            engine: id, profile: nil, resources: prepared)
        print(try encode(result))
    case "plan":
        guard let root = positional.first, let value = flags["engine"], let output = flags["output"] else {
            throw CLIError("plan requires <root> --engine <id> --output <dir>")
        }
        let project = try GamePortableProjectDescriptor(rootURL: URL(fileURLWithPath: root))
        let prepared = try resources(flags["resources"], flags["manifest"])
        let registry = try FloeGamePortableKit.registry()
        let plan = try registry.plan(project, engine: try engine(value),
            outputURL: URL(fileURLWithPath: output), resources: prepared,
            sdkURL: flags["sdk"].map { URL(fileURLWithPath: $0) })
        print(try encode(plan))
    case "templates":
        print(try encode(GamePortableTemplateCatalog.summaries()))
    case "pins":
        print(try encode(GamePortableRuntimePins.load()))
    case "assemble-mv":
        guard let root = positional.first, let output = flags["output"] else {
            throw CLIError("assemble-mv requires <root> --output <dir>")
        }
        let project = try GamePortableProjectDescriptor(rootURL: URL(fileURLWithPath: root))
        let prepared = try resources(flags["resources"], flags["manifest"])
        let result = try GamePortableMVAssembler.assemble(project: project, resources: prepared,
            to: URL(fileURLWithPath: output))
        print(try encode(result))
    case "overlay":
        guard let value = positional.first, let directory = flags["directory"] else {
            throw CLIError("overlay requires <engine> --directory <built-dir>")
        }
        try GamePortableOverlayInstaller.install(engine: try engine(value),
            into: URL(fileURLWithPath: directory))
        print("{\"ok\":true}")
    case "help", "--help", "-h":
        print(usage)
    default:
        throw CLIError("unknown command: \(command)")
    }
} catch {
    FileHandle.standardError.write(Data(("error: \(error)\n").utf8))
    exit(1)
}
